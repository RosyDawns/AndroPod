import Foundation

/// Keeps one interactive `adb shell` alive per instance and writes commands into
/// it, instead of spawning `adb` once per tap.
///
/// Why: a cold `adb -s ... shell input tap x y` costs 140-170 ms on this machine,
/// and almost all of that is the adb client binary starting up and talking to the
/// server. With a shell already open, a command costs only the guest-side
/// execution time, around 30 ms. For an emulator that is the difference between
/// "feels laggy" and "feels like a device".
///
/// The shell is also the only input path with reliable coordinates. QEMU's
/// absolute pointer device reports positions that do not line up with guest
/// pixels, while `input tap` speaks guest pixels directly.
public final class ADBShell {
    public enum ShellError: LocalizedError {
        case adbMissing
        case notRunning
        case writeFailed

        public var errorDescription: String? {
            switch self {
            case .adbMissing: return "找不到 adb，请安装 android-platform-tools"
            case .notRunning: return "adb shell 未运行"
            case .writeFailed: return "写入 adb shell 失败"
            }
        }
    }

    /// A private adb server port. The default 5037 is often occupied by a stale
    /// daemon that reports devices as healthy while every command hangs; keeping
    /// our own daemon on a separate port sidesteps that entirely.
    public static let serverPort = "5599"

    public let serial: String
    private let queue = DispatchQueue(label: "com.andropod.adb", qos: .userInteractive)
    private var process: Process?
    private var input: FileHandle?
    private var ready = false

    public init(serial: String) {
        self.serial = serial
    }

    public static var binary: String? {
        for path in ["/opt/homebrew/bin/adb", "/usr/local/bin/adb"] where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    /// Boots a clean adb server once per app run. Safe to call repeatedly.
    ///
    /// Deliberately does not wait for the process. `adb start-server` can hang
    /// indefinitely when the port is in a bad state, and an earlier version
    /// that waited here froze the whole app before it ever created a timer —
    /// which looked like a broken frame pipeline for a long time. The daemon
    /// comes up on its own; callers that need it now use `connect()`.
    public static func prepareServer() {
        guard let adb = binary else { return }
        let environment = ProcessInfo.processInfo.environment.merging(
            ["ANDROID_ADB_SERVER_PORT": serverPort]
        ) { _, new in new }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adb)
        process.arguments = ["start-server"]
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    /// Registers the device with our daemon.
    ///
    /// A daemon on a fresh port knows nothing about the guest, so `get-state`
    /// would fail and the UI would wrongly conclude adb is unusable and fall
    /// back to QMP — whose absolute coordinates do not line up with guest pixels.
    @discardableResult
    public func connect() {
        guard let adb = Self.binary else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: adb)
        task.arguments = ["connect", serial]
        task.environment = ProcessInfo.processInfo.environment.merging(
            ["ANDROID_ADB_SERVER_PORT": Self.serverPort]
        ) { _, new in new }
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return }
        // No waitUntilExit: `adb connect` can sit on a stale socket for a long
        // time, and this runs on the path that opens the persistent shell.
        return
    }

    /// Opens the persistent shell. Returns once the process is running.
    public func start() throws {
        try queue.sync { try startOnQueue() }
    }

    /// Caller must already be on `queue`. `start()` cannot be used from inside
    /// `run()`: this is a serial queue and `queue.sync` there would deadlock.
    private func startOnQueue() throws {
        guard process == nil else { return }
        guard let adb = Self.binary else { throw ShellError.adbMissing }
        connect()
        let task = Process()
            task.executableURL = URL(fileURLWithPath: adb)
            task.arguments = ["-s", serial, "shell"]
            task.environment = ProcessInfo.processInfo.environment.merging(
                ["ANDROID_ADB_SERVER_PORT": Self.serverPort]
            ) { _, new in new }

            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            task.standardInput = stdinPipe
            task.standardOutput = stdoutPipe
            task.standardError = stdoutPipe

            // Drain output. `input` prints nothing, but the shell emits a prompt
            // and any stray output would fill the pipe buffer and block the
            // process once ~64 KB accumulates.
            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                _ = handle.availableData
            }

            try task.run()
            process = task
            input = stdinPipe.fileHandleForWriting
            ready = true
    }

    public func stop() {
        queue.sync {
            ready = false
            process?.terminate()
            process = nil
            input = nil
        }
    }

    /// Runs a command in the shell. Fire-and-forget: `input` produces no output
    /// worth waiting for, and blocking here would put the UI back behind a
    /// round trip.
    public func run(_ command: String) {
        queue.async { [weak self] in
            guard let self else { return }
            if !self.ready || self.process?.isRunning != true {
                // Lazily (re)start — a cancelled shell or a guest that rebooted
                // would otherwise leave input permanently dead.
                self.ready = false
                self.process?.terminate()
                self.process = nil
                self.input = nil
                do { try self.startOnQueue() } catch { return }
            }
            self.write(command)
        }
    }

    private func write(_ command: String) {
        guard let input, let data = (command + "\n").data(using: .utf8) else { return }
        do {
            try input.write(contentsOf: data)
        } catch {
            // Broken pipe: drop the shell so the next call restarts it.
            ready = false
            process?.terminate()
            process = nil
            self.input = nil
        }
    }

    // MARK: - convenience

    public func tap(x: Int, y: Int) {
        run("input tap \(x) \(y)")
    }

    public func swipe(from: CGPoint, to: CGPoint, durationMs: Int = 240) {
        run("input swipe \(Int(from.x)) \(Int(from.y)) \(Int(to.x)) \(Int(to.y)) \(durationMs)")
    }

    /// Android key codes: 3 home, 4 back, 187 recents.
    public func keyevent(_ code: Int) {
        run("input keyevent \(code)")
    }

    public func text(_ value: String) {
        // Escape single quotes for the guest shell, then let `input text` type it.
        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        run("input text '\(escaped)'")
    }

    /// True when a shell is up and the device answers.
    public func probe() -> Bool {
        guard let adb = Self.binary else { return false }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: adb)
        task.arguments = ["-s", serial, "get-state"]
        task.environment = ProcessInfo.processInfo.environment.merging(
            ["ANDROID_ADB_SERVER_PORT": Self.serverPort]
        ) { _, new in new }
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return false }
        task.waitUntilExit()
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        return task.terminationStatus == 0
            && String(decoding: data, as: UTF8.self).contains("device")
    }
}
