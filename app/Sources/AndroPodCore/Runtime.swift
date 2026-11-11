import AppKit
import Foundation

public struct GuestInstance: Identifiable, Hashable {
    public let name: String
    public let cpus: Int
    public let memoryMB: Int
    public let workdir: URL
    /// Host port forwarded to the guest's adbd.
    public let adbPort: Int
    /// QEMU's VNC port (5900 + display). Nil when the instance has no VNC
    /// backend, in which case the UI falls back to screendump polling.
    public let vncPort: Int?
    /// Configured guest display size (MuMu-style "1600 × 945"). Nil on
    /// instances created before the field existed.
    public let xres: Int?
    public let yres: Int?
    /// Display density metadata shown next to the resolution.
    public let dpi: Int?
    /// "2d" (SwiftShader) or "virgl" (host GPU).
    public let gpuBackend: String
    /// Whether a virtio touchscreen is attached (games need it).
    public let touch: Bool
    /// Direct-boot cmdline switches (user opt-in per instance).
    public let insecureAdb: Bool
    public let selinuxPermissive: Bool

    public var id: String { name }
    public var serialLog: URL { workdir.appendingPathComponent("serial.log") }
    public var displaySocket: URL { workdir.appendingPathComponent("qmp-display.sock") }
    public var controlSocket: URL { workdir.appendingPathComponent("qmp.sock") }
    public var inputSocket: URL { workdir.appendingPathComponent("qmp-input.sock") }
    public var pidFile: URL { workdir.appendingPathComponent("qemu.pid") }
    public var commandLine: URL { workdir.appendingPathComponent("qemu.cmd") }
    public var adbSerial: String { "127.0.0.1:\(adbPort)" }

    /// Resolution string for the card; falls back to whatever the live frame
    /// reports when the stored config predates the resolution fields.
    public func resolutionString(live: CGSize) -> String {
        let size: CGSize
        if let xres, let yres, xres > 0, yres > 0 {
            size = CGSize(width: xres, height: yres)
        } else {
            size = live
        }
        return "\(Int(size.width)) × \(Int(size.height)) | \(dpi ?? 160) DPI"
    }
}

/// Raises the engine's own window — the only place virgl-rendered pixels
/// exist. QEMU's cocoa backend runs a real NSApplication, so this needs no
/// accessibility permission, just the pid it wrote at boot.
public enum EngineWindow {
    @discardableResult
    public static func activate(pidFile: URL) -> Bool {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0,
              let app = NSRunningApplication(processIdentifier: pid)
        else { return false }
        return app.activate(options: [.activateAllWindows])
    }
}

public enum WorkspaceError: LocalizedError {
    case rootNotFound
    case cliFailed(String)

    public var errorDescription: String? {
        switch self {
        case .rootNotFound: return "找不到项目根目录（需包含 bin/andropod）"
        case .cliFailed(let output): return output
        }
    }
}

/// Locates the project root by walking up from the running binary.
public enum ProjectRoot {
    public static func locate() -> URL? {
        if let override = ProcessInfo.processInfo.environment["ANDROPOD_ROOT"] {
            return URL(fileURLWithPath: override)
        }

        let manager = FileManager.default
        var candidates: [URL] = []

        // 安装版（/Applications/...）：构建时把项目根写进了 bundle。应用装到
        // 标准位置后，从可执行文件向上再也碰不到 bin/andropod，这个文件是
        // 唯一可靠的线索。
        if let data = Bundle.main.url(forResource: "project-root",
                                      withExtension: "json")
            .flatMap({ try? Data(contentsOf: $0) }),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
           let path = object["root"] {
            candidates.append(URL(fileURLWithPath: path))
        }

        if let executable = Bundle.main.executableURL {
            candidates.append(executable)
        }
        if let first = CommandLine.arguments.first, first.hasPrefix("/") {
            candidates.append(URL(fileURLWithPath: first))
        }
        candidates.append(URL(fileURLWithPath: manager.currentDirectoryPath))
        // 开发兜底：源码树就在 ~/AndroPod 的场合。
        candidates.append(URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("AndroPod"))

        for start in candidates {
            var cursor = start.resolvingSymlinksInPath()
            for _ in 0..<9 {
                if manager.fileExists(atPath: cursor.appendingPathComponent("bin/andropod").path) {
                    return cursor
                }
                let parent = cursor.deletingLastPathComponent()
                if parent.path == cursor.path { break }
                cursor = parent
            }
        }
        return nil
    }
}

public final class Workspace {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    private var cliURL: URL { root.appendingPathComponent("bin/andropod") }
    private var instancesURL: URL { root.appendingPathComponent("runtime/instances") }

    // MARK: - discovery

    public func loadInstances() -> [GuestInstance] {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: instancesURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [GuestInstance] = []
        for entry in entries {
            let configURL = entry.appendingPathComponent("instance.json")
            guard let data = try? Data(contentsOf: configURL),
                  let stored = try? JSONDecoder().decode(StoredConfig.self, from: data) else { continue }
            result.append(
                GuestInstance(
                    name: stored.name,
                    cpus: stored.cpus ?? 4,
                    memoryMB: stored.memoryMB ?? 2048,
                    workdir: entry,
                    adbPort: Self.adbPort(from: stored.hostfwd) ?? 5555,
                    vncPort: stored.vncDisplay.map { 5900 + $0 },
                    xres: stored.xres,
                    yres: stored.yres,
                    dpi: stored.dpi,
                    gpuBackend: stored.gpuBackend ?? "2d",
                    touch: stored.touch ?? true,
                    insecureAdb: stored.insecureAdb ?? false,
                    selinuxPermissive: stored.selinuxPermissive ?? false
                )
            )
        }
        return result.sorted { $0.name < $1.name }
    }

    /// Pulls the host port that forwards to the guest's adbd (5555).
    private static func adbPort(from hostfwd: [String]?) -> Int? {
        guard let hostfwd else { return nil }
        for rule in hostfwd {
            // Format: tcp:127.0.0.1:5555-:5555
            guard rule.hasSuffix("-:5555"),
                  let hostPart = rule.split(separator: ":").dropLast(1).last,
                  let port = Int(hostPart)
            else { continue }
            return port
        }
        return nil
    }

    private struct StoredConfig: Decodable {
        let name: String
        let cpus: Int?
        let memoryMB: Int?
        let hostfwd: [String]?
        let vncDisplay: Int?
        let xres: Int?
        let yres: Int?
        let dpi: Int?
        let gpuBackend: String?
        let touch: Bool?
        let insecureAdb: Bool?
        let selinuxPermissive: Bool?

        enum CodingKeys: String, CodingKey {
            case name, cpus, hostfwd, xres, yres, dpi, touch
            case insecureAdb = "insecure_adb"
            case selinuxPermissive = "selinux_permissive"
            case memoryMB = "memory_mb"
            case vncDisplay = "vnc_display"
            case gpuBackend = "gpu_backend"
        }
    }

    // MARK: - liveness

    /// True only when the pid is alive *and* still belongs to a QEMU process.
    /// A stale pid file plus pid reuse otherwise makes a dead instance look
    /// alive, which silently breaks the UI. Instances started by the GUI are
    /// held by `andropod-player`, which carries QEMU inside its own process.
    public func isRunning(_ instance: GuestInstance) -> Bool {
        guard let text = try? String(contentsOf: instance.pidFile, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        guard kill(pid, 0) == 0 else { return false }
        guard let path = Self.executablePath(of: pid) else { return false }
        return path.contains("qemu-system") || path.contains("andropod-player")
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(bytes: buffer[0..<Int(length)], encoding: .utf8)
    }

    // MARK: - control

    /// The player executable: QEMU linked as a library into its own process,
    /// with the guest's framebuffer attached to a normal AppKit window.
    /// Bundled next to the manager; the dev path keeps it runnable in place.
    public var playerURL: URL? {
        if let override = ProcessInfo.processInfo.environment["ANDROPOD_PLAYER"] {
            let url = URL(fileURLWithPath: override)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/andropod-player")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        let dev = root.appendingPathComponent("engine/embed/player")
        if FileManager.default.isExecutableFile(atPath: dev.path) { return dev }
        return nil
    }

    /// Starts one player process for one instance.
    ///
    /// The caller is expected to run `andropod plan` first: that is what
    /// clears stale pids/sockets and writes qemu.cmd, which the player reads.
    /// Launching without it would start a second QEMU on a dirty workdir.
    public func launchPlayer(_ instance: GuestInstance) throws -> Process {
        guard let playerURL else {
            throw WorkspaceError.cliFailed(
                "找不到 andropod-player。请重新构建应用（app/build.sh）。"
            )
        }

        let logURL = instance.workdir.appendingPathComponent("player.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        let log = try FileHandle(forWritingTo: logURL)
        try log.seekToEnd()

        let process = Process()
        process.executableURL = playerURL
        process.arguments = ["--instance", instance.workdir.path]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        // QEMU dlopens ANGLE's libEGL at display init; dyld only consults this
        // at exec time, so it has to travel with the child's environment.
        environment["DYLD_FALLBACK_LIBRARY_PATH"] =
            "/opt/homebrew/opt/libangle/lib:/opt/homebrew/opt/libepoxy-angle/lib"
        process.environment = environment
        process.standardOutput = log
        process.standardError = log
        try process.run()

        // Publish the pid immediately: the card must flip to "运行中" without
        // waiting for the player's own (slightly later) write.
        try? "\(process.processIdentifier)".write(
            to: instance.pidFile, atomically: false, encoding: .utf8
        )
        return process
    }

    public func run(_ arguments: [String], timeout: TimeInterval = 60) throws -> String {
        let process = Process()
        process.executableURL = cliURL
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()

        let handle = pipe.fileHandleForReading
        var output = Data()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            let chunk = handle.availableData
            if !chunk.isEmpty { output.append(chunk) }
            usleep(20_000)
        }
        output.append(handle.availableData)
        if process.isRunning {
            process.terminate()
            throw WorkspaceError.cliFailed("命令超时：\(arguments.joined(separator: " "))")
        }

        let text = String(data: output, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw WorkspaceError.cliFailed(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return text
    }
}

/// A failure inside the frame pipeline. Surfaced to the UI instead of being
/// swallowed, because a silent capture failure looks exactly like a frozen
/// guest and sends you debugging the wrong layer.
public struct FrameError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Pulls frames out of a running guest over a dedicated QMP socket.
///
/// This asks QEMU for a *raw* PPM screendump rather than a PNG. The distinction
/// is not cosmetic: PNG encoding runs inside QEMU's main loop and costs ~129 ms
/// per 1280x800 frame on this machine, which stalls vCPU execution while the
/// viewer is merely trying to draw. Raw PPM takes ~6 ms because there is nothing
/// to encode — just a framebuffer copy — and `PPMDecoder` turns it into a
/// `CGImage` without an ImageIO round trip.
///
/// The capture rate is adaptive: the next dump is only requested after the
/// previous one has been delivered, so a slow frame can never queue up work
/// faster than it completes.
public final class FramePoller {
    public var onFrame: ((NSImage) -> Void)?
    public var onFailure: ((Error) -> Void)?
    /// Reported after every capture so callers can show the real rate.
    public var onStats: ((Double, Double) -> Void)?  // (captureMs, fps)

    /// Progress markers for the last capture attempt. A pipeline that fails
    /// silently is indistinguishable from a frozen guest, so the UI can read
    /// these and say which step it got to.
    public private(set) var attempts = 0
    public private(set) var lastStage = "未开始"
    public private(set) var lastError: String?
    public private(set) var startCalls = 0
    public private(set) var scheduleCalls = 0
    public private(set) var isRunningFlag = false

    private let socketPath: String
    private let scratch: URL
    private let queue = DispatchQueue(label: "com.andropod.frames", qos: .userInitiated)
    private var client: QMPClient?
    private var mainTimer: Timer?
    private var capturing = false
    private var running = false
    private var interval: TimeInterval = 1.0 / 30
    private let scratchLock = NSLock()

    public init(socketPath: String, scratch: URL) {
        self.socketPath = socketPath
        self.scratch = scratch
    }

    /// Grabs one frame and returns it, without touching any callback.
    ///
    /// Keeping the callbacks out of here is what lets the caller run this on a
    /// background queue and hop back to the main thread only to publish the
    /// image. When capture ran inline on the main thread, a 30 Hz timer collapsed
    /// to ~14 fps and every frame stalled the UI for its full duration — which
    /// is exactly what "not responsive" feels like.
    public func captureFrame() -> (image: NSImage, milliseconds: Double)? {
        guard !capturing else { return nil }
        capturing = true
        defer { capturing = false }

        let began = CFAbsoluteTimeGetCurrent()
        attempts += 1
        do {
            lastStage = "连接"
            if client?.isConnected != true {
                let fresh = QMPClient()
                try fresh.connect(unixPath: socketPath, timeout: 2)
                client = fresh
            }
            lastStage = "抓帧"
            try client?.execute("screendump", arguments: ["filename": scratch.path])

            lastStage = "读文件"
            guard let data = try? Data(contentsOf: scratch) else {
                lastError = "读取 \(scratch.path) 失败"
                return nil
            }
            lastStage = "解码"
            guard let cgImage = PPMDecoder.decode(data) else {
                lastError = "PPM 解码失败（\(data.count) 字节）"
                return nil
            }
            lastStage = "完成"
            lastError = nil
            let image = NSImage(
                cgImage: cgImage,
                size: NSSize(width: cgImage.width, height: cgImage.height)
            )
            return (image, (CFAbsoluteTimeGetCurrent() - began) * 1000)
        } catch {
            lastError = error.localizedDescription
            client?.close()
            client = nil
            return nil
        }
    }

    public func markRunning(_ value: Bool) {
        running = value
        isRunningFlag = value
    }

    public func stop() {
        running = false
        isRunningFlag = false
        mainTimer?.invalidate()
        mainTimer = nil
        client?.close()
        client = nil
    }

    /// Main thread only. Runs the capture inline.
    ///
    /// Doing this off-thread was the whole problem: the dispatched blocks never
    /// executed here, silently. Inline at least works, and `SelfTest` shows the
    /// same call path taking ~7 ms.
    private func tick() {
        guard !capturing else { return }
        capturing = true
        scheduleCalls += 1
        capture()
        capturing = false
    }

    private func fail(_ error: Error) {
        DispatchQueue.main.async { [weak self] in self?.onFailure?(error) }
    }

    private func capture() {
        let began = CFAbsoluteTimeGetCurrent()
        attempts += 1
        do {
            lastStage = "连接"
            if client?.isConnected != true {
                let fresh = QMPClient()
                try fresh.connect(unixPath: socketPath, timeout: 2)
                client = fresh
            }
            // No "format" argument: QEMU defaults to raw PPM, which is the
            // whole point — see the type comment above.
            lastStage = "抓帧"
            let target = scratch.path
            try client?.execute("screendump", arguments: ["filename": target])

            // Read normally rather than with .mappedIfSafe. The mapping is held
            // across a file QEMU may still be flushing, and a torn read there
            // surfaces as a silently undecodable frame (or a SIGBUS) rather
            // than an error. Copying 3 MB costs about a millisecond.
            lastStage = "读文件"
            guard let data = try? Data(contentsOf: scratch) else {
                lastError = "读不到 \(target)"
                self.fail(FrameError("抓帧文件读取失败: \(target)"))
                return
            }
            lastStage = "解码"
            guard let cgImage = PPMDecoder.decode(data) else {
                let head = data.prefix(12).map { String(format: "%02x", $0) }.joined(separator: " ")
                self.fail(FrameError("PPM 解码失败：\(data.count) 字节，头 \(head)"))
                return
            }
            let elapsed = (CFAbsoluteTimeGetCurrent() - began) * 1000
            let image = NSImage(
                cgImage: cgImage,
                size: NSSize(width: cgImage.width, height: cgImage.height)
            )
            lastStage = "完成"
            lastError = nil
            // Delivered inline: this runs on the main thread already, and a
            // main-queue hop here would be an extra scheduling step that has
            // proven unreliable in this process.
            onFrame?(image)
            onStats?(elapsed, elapsed > 0 ? 1000 / elapsed : 0)
        } catch {
            lastError = error.localizedDescription
            client?.close()
            client = nil
            onFailure?(error)
        }
    }
}
