import AndroPodCore
import AppKit
import Foundation
import SwiftUI

/// Shared state for the whole app: the device list, live frames, and actions.
///
/// Frames are kept here rather than inside the device window so that a single
/// QMP display connection per instance can feed both the grid thumbnail and the
/// device window — the display socket only accepts one client at a time.
final class AppModel: ObservableObject {
    @Published var instances: [GuestInstance] = []
    @Published var runningNames: Set<String> = []
    @Published var frames: [String: NSImage] = [:]
    @Published var status: String = "就绪"
    @Published var lastError: String?
    @Published var working = false
    @Published var guestSize = CGSize(width: 1280, height: 800)
    /// Measured end-to-end cost of the newest frame, in milliseconds.
    @Published var frameMs: Double = 0

    /// Instance whose device window is on screen. Only this one streams at full
    /// rate; the rest idle at thumbnail rate, because every screendump occupies
    /// QEMU's main loop for several milliseconds and competes with the guest.
    @Published var focusedInstance: String?

    private var workspace: Workspace?
    private var pollers: [String: FramePoller] = [:]
    private var inputs: [String: InputClient] = [:]
    private var shells: [String: ADBShell] = [:]
    private var adbReachable: [String: Bool] = [:]
    private let captureQueue = DispatchQueue(label: "com.andropod.capture", qos: .userInitiated)
    private var captureInFlight = false
    private let flightLock = NSLock()
    private var tickCount = 0
    private var pumpCount = 0
    private var pumpNote = "未调用"
    private var initOnMain = false
    private var heartbeatCount = 0
    private var lastCapture: [String: Date] = [:]
    private var heartbeat: Timer?

    /// Full rate for the device window; slideshow rate for grid thumbnails.
    private static let liveFPS: Double = 30
    private static let thumbnailFPS: Double = 2

    init() {
        initOnMain = Thread.isMainThread
        workspace = ProjectRoot.locate().map { Workspace(root: $0) }
        if workspace == nil {
            lastError = "找不到项目根目录，请从 AndroPod 项目内启动"
        }
        // Bring up our own adb daemon on a private port before anything tries
        // to talk to a device. The default port is frequently held by a stale
        // daemon that lists devices as healthy while every command hangs.
        ADBShell.prepareServer()
        refresh()
        // dumpDiagnostics() 移出启动路径：在 init 里调用会卡住，见下。


        // One timer drives everything. A second timer for frame pumping never
        // fired in this process even though this one does — so rather than
        // debug the difference, frames ride on the timer that works. At 30 Hz
        // the slower housekeeping runs every 75th tick (2.5 s).
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) {
            [weak self] _ in
            // Called directly: Timer already fires on the main runloop, and a
            // Task hop here cost far more than it bought.
            guard let self else { return }
            self.heartbeatCount += 1
            if self.heartbeatCount <= 2 {
            }
            self.pumpFrames()
            self.tickCount += 1
            guard self.tickCount <= 3 || self.tickCount % 75 == 0 else { return }
            self.refresh()
            self.recheckADB()
            self.dumpDiagnostics()
        }
        // .common, not the default mode: a timer added with scheduledTimer only
        // fires in .default, and this app spends time in other modes, which is
        // why every earlier attempt looked like a dead timer.
        RunLoop.main.add(timer, forMode: .common)
        self.heartbeat = timer

        // lets a headless run pin the "visible" instance for measurement
        if let forced = ProcessInfo.processInfo.environment["ANDROPOD_FOCUS"],
           pollers[forced] != nil {
            focusedInstance = forced
        }

        // lets a headless run pin the "visible" instance for measurement
        if let forced = ProcessInfo.processInfo.environment["ANDROPOD_FOCUS"],
           pollers[forced] != nil {
            focusedInstance = forced
        }
    }

    deinit {
        heartbeat?.invalidate()
    }

    // MARK: - data

    func refresh() {
        guard let workspace else { return }
        let loaded = workspace.loadInstances()
        instances = loaded

        let running = Set(loaded.filter { workspace.isRunning($0) }.map(\.name))
        if running != runningNames {
            runningNames = running
        }

        for name in running {
            startPolling(name)
        }
        for (name, poller) in pollers where !running.contains(name) {
            poller.stop()
            pollers.removeValue(forKey: name)
            frames.removeValue(forKey: name)
        }
        for (name, client) in inputs where !running.contains(name) {
            client.disconnect()
            inputs.removeValue(forKey: name)
        }
        for (name, shell) in shells where !running.contains(name) {
            shell.stop()
            shells.removeValue(forKey: name)
            adbReachable.removeValue(forKey: name)
        }
    }

    func isRunning(_ instance: GuestInstance) -> Bool {
        runningNames.contains(instance.name)
    }

    func frame(for instance: GuestInstance) -> NSImage? {
        frames[instance.name]
    }

    // MARK: - frames

    private func startPolling(_ name: String) {
        guard pollers[name] == nil else { return }
        guard let instance = instances.first(where: { $0.name == name }) else { return }

        // ".ppm" is not cosmetic: QEMU's screendump picks its encoder from the
        // format argument, and we deliberately pass none so it writes raw PPM.
        // Assigning a .png scratch path here once cost 15x throughput.
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("andropod-frame-\(name).ppm")
        let poller = FramePoller(socketPath: instance.displaySocket.path, scratch: scratch)
        poller.onFrame = { [weak self] image in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.frames[name] = image
                if image.size.width > 0, image.size != self.guestSize {
                    self.guestSize = image.size
                }
            }
        }
        poller.onStats = { [weak self] captureMs, _ in
            Task { @MainActor [weak self] in
                guard let self, self.focusedInstance == name else { return }
                self.frameMs = captureMs
            }
        }
        // Capture failures repeat every tick, so only surface a change.
        poller.onFailure = { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let message = "画面：\(error.localizedDescription)"
                if self.lastError != message { self.lastError = message }
            }
        }
        poller.markRunning(true)
        pollers[name] = poller
    }

    /// Captures at most one instance per tick, choosing whichever is furthest
    /// behind its target rate. Serialising this way keeps a frame (about 7 ms)
    /// from stacking up when several instances are running.
    private func pumpFrames() {
        pumpCount += 1
        guard !captureInFlight, !pollers.isEmpty else { return }

        let now = Date()
        var chosen: (name: String, poller: FramePoller)?

        // The visible instance gets first refusal on every tick; thumbnails only
        // fill ticks it does not need. Sharing the queue evenly starved the
        // focused window whenever a background guest had a large lag.
        if let focused = focusedInstance, let poller = pollers[focused] {
            let interval = 1.0 / Self.liveFPS
            if now.timeIntervalSince(lastCapture[focused] ?? .distantPast) >= interval {
                chosen = (focused, poller)
            }
        }
        if chosen == nil {
            var bestLag = 0.0
            for (name, poller) in pollers where name != focusedInstance {
                let interval = 1.0 / Self.thumbnailFPS
                let lag = now.timeIntervalSince(lastCapture[name] ?? .distantPast)
                guard lag >= interval, lag > bestLag else { continue }
                bestLag = lag
                chosen = (name, poller)
            }
        }
        guard let chosen else { return }

        lastCapture[chosen.name] = now
        captureInFlight = true
        let name = chosen.name
        let poller = chosen.poller

        // Off the main thread. A capture blocks for its whole duration on QMP
        // I/O plus decoding; running that inline throttled the UI timer and made
        // every interaction feel delayed.
        captureQueue.async { [weak self] in
            let result = poller.captureFrame()
            // Release the in-flight flag here, not in the main-thread callback.
            // Waiting for the UI hop meant a busy main thread silently skipped
            // every other capture, halving the frame rate to ~15 fps.
            if let self {
                self.flightLock.lock()
                self.captureInFlight = false
                self.flightLock.unlock()
            }
            guard let self else { return }
            DispatchQueue.main.async {
                if let result {
                    self.frames[name] = result.image
                    if name == self.focusedInstance {
                        self.frameMs = result.milliseconds
                    }
                    if result.image.size.width > 0, result.image.size != self.guestSize {
                        self.guestSize = result.image.size
                    }
                }
            }
        }
    }


    /// Raise the capture rate for the instance now on screen and drop the rest
    /// back to thumbnail cadence.
    func focus(_ name: String?) {
        focusedInstance = name
        // Clear the schedule so the newly focused instance is captured on the
        // next tick instead of waiting out its thumbnail interval.
        if let name { lastCapture[name] = .distantPast }
    }

    // MARK: - actions

    func start(_ instance: GuestInstance) {
        run(instance, label: "开机中…") { workspace in
            do {
                return try workspace.run(
                    ["boot", "--name", instance.name, "--snapshot", "clean"], timeout: 90
                )
            } catch {
                return try workspace.run(
                    ["start", "--name", instance.name, "--wait-for", "__none__"], timeout: 60
                ) + "\n(无快照，已冷启动；首次使用请点「初始化」)"
            }
        }
    }

    func stop(_ instance: GuestInstance) {
        run(instance, label: "关机中…") { workspace in
            try workspace.run(["stop", "--name", instance.name], timeout: 40)
        }
    }

    func snapshot(_ instance: GuestInstance) {
        let tag = "snap-\(Self.timestamp())"
        run(instance, label: "保存快照…") { workspace in
            try workspace.run(["snap", tag, "--name", instance.name], timeout: 120)
        }
    }

    func restore(_ instance: GuestInstance) {
        run(instance, label: "恢复快照…") { workspace in
            try workspace.run(["restore", "clean", "--name", instance.name], timeout: 120)
        }
    }

    func provision(_ instance: GuestInstance) {
        run(instance, label: "初始化中：退出回收模式、跳过向导…") { workspace in
            try workspace.run(["provision", "--name", instance.name], timeout: 900)
        }
    }

    func createInstance() {
        guard let workspace else { return }
        let existing = Set(instances.map(\.name))
        var index = 1
        while existing.contains("device-\(index)") { index += 1 }
        let name = "device-\(index)"

        working = true
        status = "创建 \(name)…"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try workspace.run(["create", "--name", name], timeout: 60)
                DispatchQueue.main.async {
                    self.working = false
                    self.status = "已创建 \(name)"
                    self.refresh()
                }
            } catch {
                DispatchQueue.main.async {
                    self.working = false
                    self.status = "创建失败"
                    self.lastError = error.localizedDescription
                }
            }
        }
    }

    // MARK: - input

    /// Prefers adb: it speaks guest pixels directly and can send the real
    /// Android key codes for back/home/recents, which QEMU's HID keyboard
    /// simply does not have. Falls back to QMP when adb is unreachable, which
    /// happens on a guest that has not finished booting.
    private func shell(for instance: GuestInstance) -> ADBShell? {
        if let existing = shells[instance.name] { return existing }
        guard adbReachable[instance.name] != false else { return nil }
        let shell = ADBShell(serial: instance.adbSerial)
        do {
            try shell.start()
            shells[instance.name] = shell
            return shell
        } catch {
            adbReachable[instance.name] = false
            return nil
        }
    }

    func tap(_ point: CGPoint, on instance: GuestInstance) {
        // QMP pointer events, not adb. Both reach the same surfaces, but
        // `adb shell input tap` makes the guest fork a Java process for the
        // command — 30-80 ms of added latency per tap, which is exactly the
        // "feels disconnected" complaint. This path is sub-millisecond.
        input(for: instance).tap(x: Int(point.x), y: Int(point.y))
    }

    func swipe(from: CGPoint, to: CGPoint, on instance: GuestInstance) {
        input(for: instance).swipe(from: from, to: to)
    }

    /// Accepts Android key names or QEMU qcodes.
    func key(_ name: String, on instance: GuestInstance) {
        let upper = name.uppercased()
        let androidCode: Int?
        switch upper {
        case "BACK": androidCode = 4
        case "HOME": androidCode = 3
        case "RECENTS", "APP_SWITCH": androidCode = 187
        case "ENTER", "RET": androidCode = 66
        case "POWER": androidCode = 26
        case "VOLUME_UP": androidCode = 24
        case "VOLUME_DOWN": androidCode = 25
        default: androidCode = nil
        }
        if let code = androidCode, let shell = shell(for: instance) {
            shell.keyevent(code)
            return
        }
        input(for: instance).key(name.lowercased())
    }

    /// One long-lived QMP input socket per instance, used only when adb is out.
    private func input(for instance: GuestInstance) -> InputClient {
        if let existing = inputs[instance.name] {
            existing.screen = InputClient.Screen(
                width: Int(guestSize.width), height: Int(guestSize.height)
            )
            return existing
        }
        let client = InputClient(socketPath: instance.inputSocket.path)
        client.screen = InputClient.Screen(
            width: Int(guestSize.width), height: Int(guestSize.height)
        )
        client.onError = { [weak self] message in
            Task { @MainActor [weak self] in self?.lastError = "输入注入失败：\(message)" }
        }
        inputs[instance.name] = client
        return client
    }

    /// Re-probes adb for instances that previously failed, so a guest that
    /// finished booting starts getting proper input without a restart.
    private func recheckADB() {
        for instance in instances where runningNames.contains(instance.name) {
            if adbReachable[instance.name] == false || shells[instance.name] == nil {
                let serial = instance.adbSerial
                let name = instance.name
                DispatchQueue.global(qos: .utility).async {
                    let probe = ADBShell(serial: serial)
                    let ok = probe.probe()
                    DispatchQueue.main.async { [weak self] in
                        self?.adbReachable[name] = ok
                    }
                }
            }
        }
    }

    func screenshot(_ instance: GuestInstance) {
        guard let workspace else { return }
        let relative = "runtime/instances/\(instance.name)/screens/\(Self.timestamp()).png"
        let target = workspace.root.appendingPathComponent(relative)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try workspace.run(["shot", target.path, "--name", instance.name], timeout: 30)
                DispatchQueue.main.async {
                    self.status = "截图已保存：\(relative)"
                    NSWorkspace.shared.activateFileViewerSelecting([target])
                }
            } catch {
                DispatchQueue.main.async { self.lastError = error.localizedDescription }
            }
        }
    }

    // MARK: - plumbing

    private func run(
        _ instance: GuestInstance,
        label: String,
        _ body: @escaping (Workspace) throws -> String
    ) {
        guard let workspace, !working else { return }
        working = true
        status = "\(instance.name)：\(label)"
        lastError = nil

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let output = try body(workspace)
                DispatchQueue.main.async {
                    self.working = false
                    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.status = trimmed.isEmpty ? "完成" : trimmed
                    self.refresh()
                }
            } catch {
                DispatchQueue.main.async {
                    self.working = false
                    self.status = "失败"
                    self.lastError = error.localizedDescription
                }
            }
        }
    }

    func clearError() {
        lastError = nil
    }

    /// Writes a small snapshot of internal state to /tmp so the app can be
    /// inspected without a debugger or a screenshot. The GUI is often behind
    /// other windows, and "is it actually capturing frames?" is otherwise
    /// impossible to answer from outside.
    private func dumpDiagnostics() {
        // Plain text, no JSONSerialization: mixing Any values in a dictionary
        // there can raise an NSException that `try?` cannot catch, which kills
        // the process with SIGTRAP.
        var lines: [String] = []
        lines.append("root=" + (workspace?.root.path ?? "nil"))
        lines.append("instances=" + instances.map(\.name).joined(separator: ","))
        lines.append("running=" + runningNames.sorted().joined(separator: ","))
        lines.append("pump=\(pumpCount) \(pumpNote)")
        lines.append("heartbeat=\(heartbeatCount) tick=\(tickCount)")
        lines.append("frameMs=\(frameMs)")
        lines.append("frames=" + frames.map { "\($0.key):\(Int($0.value.size.width))x\(Int($0.value.size.height))" }.joined(separator: ","))
        for (name, poller) in pollers {
            lines.append("poller.\(name)=start=\(poller.startCalls) sched=\(poller.scheduleCalls) attempts=\(poller.attempts) stage=\(poller.lastStage)")
        }
        lines.append("error=" + (lastError ?? ""))
        if let data = lines.joined(separator: "\n").data(using: .utf8) {
            try? data.write(to: URL(fileURLWithPath: "/tmp/andropod-gui.txt"))
        }
    }



    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
