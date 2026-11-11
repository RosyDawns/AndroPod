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
    /// Measured cost of building the newest frame, in milliseconds.
    @Published var frameMs: Double = 0
    /// Frames actually delivered per second (VNC path only).
    @Published var frameFps: Double = 0
    /// Bytes received on the VNC connection since it opened.
    @Published var vncBytes: Int = 0
    /// "VNC / ZRLE" or "screendump" per instance, shown in the device window.
    @Published var displayMode: [String: String] = [:]

    /// Sheet/alert targets live here rather than in @State on the card:
    /// this toolchain's SwiftUI macro plugins are incomplete (no @State),
    /// and card-local bindings would need them.
    @Published var settingsFor: String?
    @Published var deleteConfirmFor: String?
    /// Instance waiting on the GPU consent prompt (see `needsGPUConsent`).
    /// Set by `start()`, cleared by the alert's confirm/cancel.
    @Published var gpuSetupFor: String?
    /// Measured on-disk size of each instance directory (bytes), computed
    /// lazily in the background when the settings sheet opens.
    @Published var diskUsageBytes: [String: Int64] = [:]

    /// Writes selected fields straight into instance.json. Only meaningful
    /// while the guest is off — QEMU reads these at boot — so callers should
    /// surface the "下次开机生效" hint. Unknown keys in the JSON survive:
    /// the file is loaded as a dict and mutated, never rebuilt.
    @discardableResult
    func updateInstanceConfig(
        _ instance: GuestInstance,
        cpus: Int? = nil,
        memoryMB: Int? = nil,
        xres: Int? = nil,
        yres: Int? = nil,
        dpi: Int? = nil,
        gpuBackend: String? = nil,
        touch: Bool? = nil,
        insecureAdb: Bool? = nil,
        selinuxPermissive: Bool? = nil
    ) -> Bool {
        let url = instance.workdir.appendingPathComponent("instance.json")
        do {
            guard var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
                as? [String: Any] else {
                lastError = "instance.json 不是合法对象"
                return false
            }
            if let cpus { json["cpus"] = cpus }
            if let memoryMB { json["memory_mb"] = memoryMB }
            if let xres { json["xres"] = xres }
            if let yres { json["yres"] = yres }
            if let dpi { json["dpi"] = dpi }
            if let gpuBackend {
                json["gpu_backend"] = gpuBackend
                json["gpu"] = true
            }
            if let touch { json["touch"] = touch }
            if let insecureAdb { json["insecure_adb"] = insecureAdb }
            if let selinuxPermissive { json["selinux_permissive"] = selinuxPermissive }
            let data = try JSONSerialization.data(
                withJSONObject: json, options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: url)
            status = "配置已保存\(runningNames.contains(instance.name) ? "（实例运行中，下次开机生效）" : "，下次开机生效")"
            refresh()
            return true
        } catch {
            lastError = "保存配置失败：\(error.localizedDescription)"
            return false
        }
    }

    /// Total size of an instance directory, on a background queue. Results
    /// land in `diskUsageBytes` keyed by instance name.
    func computeDiskUsage(_ instance: GuestInstance) {
        let workdir = instance.workdir
        let name = instance.name
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let bytes = Self.directorySize(workdir)
            DispatchQueue.main.async { self?.diskUsageBytes[name] = bytes }
        }
    }

    private static func directorySize(_ url: URL) -> Int64 {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }

    /// Instance whose device window is on screen. Only this one streams at full
    /// rate on the *screendump* path; VNC is push-based and needs no rate
    /// control, because QEMU sends nothing at all while the screen is idle.
    @Published var focusedInstance: String?

    private var workspace: Workspace?
    private var pollers: [String: FramePoller] = [:]
    private var vncClients: [String: VNCClient] = [:]
    /// Instances whose VNC handshake failed enough times to give up this boot.
    /// Cleared when the instance stops, so a later boot retries the fast path.
    private var vncFailed: Set<String> = []
    private var vncRetries: [String: Int] = [:]
    /// Instances whose VNC client has delivered at least one real frame. Until
    /// then we keep the screendump poller alive so the window is never blank.
    private var vncReady: Set<String> = []
    private var inputs: [String: InputClient] = [:]
    private var shells: [String: ADBShell] = [:]
    /// Player processes this manager spawned, keyed by instance. One process
    /// per device (QEMU is embedded, not forked), so this is also the thing
    /// that tells us a window belongs to us rather than to an older session.
    private var players: [String: Process] = [:]
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
        // 自动准备暂时关闭：客机的"正常关机"链路还没验证通过，
        // 之前一次硬停就把母盘的 vfat 固件分区写坏，导致所有克隆无限重启。
        // 等 stop --graceful 能稳定拿到 `reboot: Power down` 再打开。
        // ensureBasePrepared()
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
        for (name, client) in vncClients where !running.contains(name) {
            client.stop()
            vncClients.removeValue(forKey: name)
        }
        for name in Array(vncFailed) where !running.contains(name) {
            // A fresh boot should retry the fast path from scratch.
            vncFailed.remove(name)
            vncRetries.removeValue(forKey: name)
        }
        for name in Array(vncReady) where !running.contains(name) {
            vncReady.remove(name)
            displayMode.removeValue(forKey: name)
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

    /// MuMu ships an already-provisioned user image, so its "new device" is a
    /// clone of a system that has already been through setup. We reach the same
    /// end state one step later: the first launch finishes Android's setup once
    /// and freezes that state back into the template. After this, no new device
    /// boots into the wizard — and nobody has to run a command.
    private func ensureBasePrepared() {
        guard let workspace else { return }
        let marker = workspace.root
            .appendingPathComponent("runtime/images/.base-provisioned")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        guard let template = instances.first, !working else { return }
        // A running device owns its disk; preparing would collide with it.
        guard !workspace.isRunning(template) else { return }

        working = true
        status = "首次启动：正在准备系统（完成安卓初始化，约 40 秒）…"
        lastError = nil

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try workspace.run(
                    ["prepare-base", "--name", template.name], timeout: 600
                )
                DispatchQueue.main.async {
                    self.working = false
                    self.status = "系统准备完成：新建实例将直接进入桌面"
                    self.refresh()
                }
            } catch {
                DispatchQueue.main.async {
                    self.working = false
                    self.status = "系统准备失败"
                    self.lastError = error.localizedDescription
                }
            }
        }
    }

    func isRunning(_ instance: GuestInstance) -> Bool {
        runningNames.contains(instance.name)
    }

    func frame(for instance: GuestInstance) -> NSImage? {
        frames[instance.name]
    }

    // MARK: - frames

    /// Sets up both display paths for one running instance.
    ///
    /// VNC is the fast path: QEMU pushes compressed dirty rectangles and the
    /// host never polls. But the VNC port comes up slightly after QEMU's QMP
    /// socket, and an older instance may have no VNC at all, so a screendump
    /// poller is kept alive until the first RFB frame actually arrives. Once it
    /// does, the poller is stopped for good — no more 3 MB dumps in QEMU's main
    /// loop, and no more 60 Hz timer work on the host.
    private func startPolling(_ name: String) {
        guard let instance = instances.first(where: { $0.name == name }) else { return }

        // virgl renders straight into host GPU memory and QEMU presents it in
        // its own cocoa (ANGLE/Metal) window. There is no framebuffer for the
        // host to read: VNC is rejected next to a GL context, and screendump
        // comes back black. Skipping both here is not cosmetic — polling a
        // 3 MB dump at 30 Hz for frames that never arrive is exactly the kind
        // of overhead that made 2D instances feel slower than they already are.
        if instance.gpuBackend == "virgl" {
            displayMode[name] = "GPU"
            return
        }

        // Once VNC has taken over, never rebuild the poller. refresh() calls
        // this every 2.5 s, and without this guard it would recreate the very
        // screendump loop we just retired, silently putting the guest back on
        // the 3 MB-per-frame path.
        if pollers[name] == nil, !vncReady.contains(name) {
            // ".ppm" is not cosmetic: QEMU's screendump picks its encoder from
            // the filename, and we deliberately pass none so it writes raw PPM.
            let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("andropod-frame-\(name).ppm")
            let poller = FramePoller(socketPath: instance.displaySocket.path, scratch: scratch)
            poller.onFrame = { [weak self] image in
                DispatchQueue.main.async {
                    guard let self, !self.vncReady.contains(name) else { return }
                    self.frames[name] = image
                    if image.size.width > 0, image.size != self.guestSize {
                        self.guestSize = image.size
                    }
                }
            }
            poller.onStats = { [weak self] captureMs, _ in
                DispatchQueue.main.async {
                    guard let self, self.focusedInstance == name,
                          !self.vncReady.contains(name) else { return }
                    self.frameMs = captureMs
                }
            }
            poller.onFailure = { [weak self] error in
                DispatchQueue.main.async {
                    guard let self, !self.vncReady.contains(name) else { return }
                    let message = "画面：\(error.localizedDescription)"
                    if self.lastError != message { self.lastError = message }
                }
            }
            poller.markRunning(true)
            pollers[name] = poller
            displayMode[name] = "screendump"
        }

        guard let port = instance.vncPort,
              !vncFailed.contains(name),
              !vncReady.contains(name),
              vncClients[name] == nil else { return }

        let client = VNCClient(port: port)
        client.onFrame = { [weak self] image in
            DispatchQueue.main.async {
                guard let self else { return }
                if !self.vncReady.contains(name) {
                    self.vncReady.insert(name)
                    self.vncRetries.removeValue(forKey: name)
                    self.displayMode[name] = "VNC / ZRLE"
                    // Retire the polling path: it would otherwise keep asking
                    // QEMU for full-screen dumps for no reason.
                    self.pollers[name]?.stop()
                    self.pollers.removeValue(forKey: name)
                    self.lastError = nil
                }
                self.frames[name] = image
                if image.size.width > 0, image.size != self.guestSize {
                    self.guestSize = image.size
                }
            }
        }
        client.onStats = { [weak self] buildMs, fps, bytes, _ in
            DispatchQueue.main.async {
                guard let self, self.focusedInstance == name else { return }
                self.frameMs = buildMs
                self.frameFps = fps
                self.vncBytes = bytes
            }
        }
        client.onFailure = { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.vncClients[name]?.stop()
                self.vncClients.removeValue(forKey: name)
                self.vncReady.remove(name)
                let attempts = (self.vncRetries[name] ?? 0) + 1
                self.vncRetries[name] = attempts
                // refresh() runs every 2.5 s and will call startPolling again,
                // so a transient "VNC not listening yet" simply retries.
                if attempts >= 3 {
                    self.vncFailed.insert(name)
                    self.displayMode[name] = "screendump（VNC 不可用）"
                    self.lastError = "VNC 连接失败，已回退抓帧：\(error.localizedDescription)"
                }
            }
        }
        vncClients[name] = client
        client.start()
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
        // Never flip security-relevant guest switches on the user's behalf.
        // virgl cannot render without them, so the honest move is to park the
        // boot here and ask once, with the reason spelled out.
        if needsGPUConsent(instance) {
            gpuSetupFor = instance.name
            status = "「\(instance.name)」启用 GPU 前需要确认两项客机开关"
            return
        }
        boot(instance)
    }

    /// virgl renders through the guest's own Mesa/virgl driver: every app
    /// process needs udmabuf access (denied under enforcing SELinux, so all
    /// surfaces come out black — E9) and the host needs adbd to reach the
    /// guest for input and screenshots.
    func needsGPUConsent(_ instance: GuestInstance) -> Bool {
        instance.gpuBackend == "virgl"
            && (!instance.selinuxPermissive || !instance.insecureAdb)
    }

    /// Runs only from the consent alert's confirm button — the user has just
    /// read what the two switches do and agreed to them.
    func enableGPUAndStart(_ instance: GuestInstance) {
        gpuSetupFor = nil
        guard updateInstanceConfig(
            instance, insecureAdb: true, selinuxPermissive: true
        ) else { return }
        if let fresh = instances.first(where: { $0.name == instance.name }) {
            boot(fresh)
        }
    }

    private func boot(_ instance: GuestInstance) {
        guard let workspace else { return }
        working = true
        status = "\(instance.name)：开机中…"
        lastError = nil

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // `plan` owns everything that must happen before QEMU starts:
                // stale pid/socket cleanup, argv construction, and the
                // snapshot-vs-cold decision. The player only execs what it
                // finds in qemu.cmd — running it against a dirty workdir would
                // put two QEMUs on the same disk.
                // 快照恢复（loadvm）下 virtio-gpu 的 blob/host-visible 显存
                // 映射会失效：update 回调在跑，但读到的是旧映射的数据，画面
                // 冻结在恢复时刻（2026-11-11 实测，QEMU 上游恢复语义问题）。
                // 在修好之前一律冷启动 —— 冷启动的显示已验证 100% 实时。
                let plan = try workspace.run(
                    ["plan", "--name", instance.name],
                    timeout: 30
                )
                let process = try workspace.launchPlayer(instance)
                process.terminationHandler = { [weak self] _ in
                    DispatchQueue.main.async {
                        self?.players.removeValue(forKey: instance.name)
                        self?.refresh()
                    }
                }

                DispatchQueue.main.async {
                    self.players[instance.name] = process
                    self.working = false
                    self.status = Self.bootSummary(plan) ?? "\(instance.name) 已开机"
                    self.refresh()
                    // The player is a separate app: without a nudge it can open
                    // behind the manager, which reads as "nothing happened".
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        EngineWindow.activate(pidFile: instance.pidFile)
                    }
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

    /// `plan` prints its verdict ("virgl ... 本次冷启动") before the JSON blob,
    /// so parse from the first brace instead of assuming the whole stdout is
    /// JSON. Keeping the note in the status bar is the point: a cold boot is
    /// 25–40 s and must not look like a hang.
    private static func bootSummary(_ output: String) -> String? {
        guard let start = output.firstIndex(of: "{"),
              let data = String(output[start...]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = object["name"] as? String else { return nil }
        if let snapshot = object["snapshot"] as? String {
            return "\(name) 已从快照 \(snapshot) 开机"
        }
        return "\(name) 已冷启动"
    }

    func stop(_ instance: GuestInstance) {
        run(instance, label: "关机中…", onSuccess: { _ in
            self.players.removeValue(forKey: instance.name)
        }) { workspace in
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
        createInstance(preset: .tablet)
    }

    /// MuMu-style presets: the plus menu offers 平板 and 手机, each mapping to
    /// a fixed CPU/memory/display shape. Created instances use the default
    /// Alpine test guest today — same semantics as the old single "新建" button.
    func createInstance(preset: DevicePreset) {
        guard let workspace else { return }
        let existing = Set(instances.map(\.name))
        var index = 1
        while existing.contains("device-\(index)") { index += 1 }
        let name = "device-\(index)"

        working = true
        status = "创建 \(name)（\(preset.label)）…"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try workspace.run([
                    "create", "--name", name,
                    "--cpus", String(preset.cpus),
                    "--memory", String(preset.memoryMB),
                    "--xres", String(preset.xres),
                    "--yres", String(preset.yres),
                    "--dpi", String(preset.dpi),
                    // MuMu-grade default: real host GPU. 2D/SwiftShader is a
                    // debugging fallback, never what a new device gets.
                    "--gpu-backend", "virgl",
                ], timeout: 60)
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

    /// MuMu-style "复制": full config + disk clone under an auto name
    /// ("device-1" → "device-2", or "foo" → "foo-1"). Requires the source
    /// to be stopped; the engine refuses otherwise and we surface that.
    func duplicate(_ instance: GuestInstance) {
        guard let workspace else { return }
        let target = Self.nextCloneName(of: instance.name, taken: Set(instances.map(\.name)))
        working = true
        status = "复制 \(instance.name) → \(target)…"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try workspace.run(
                    ["clone", "--name", instance.name, "--to", target], timeout: 300
                )
                DispatchQueue.main.async {
                    self.working = false
                    self.status = "已复制为 \(target)"
                    self.refresh()
                }
            } catch {
                DispatchQueue.main.async {
                    self.working = false
                    self.status = "复制失败"
                    self.lastError = error.localizedDescription
                }
            }
        }
    }

    /// MuMu-style "删除": stops the guest if needed, then removes the whole
    /// instance directory. The confirmation dialog lives in the view.
    func delete(_ instance: GuestInstance) {
        guard let workspace else { return }
        working = true
        status = "删除 \(instance.name)…"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                if self.runningNames.contains(instance.name) {
                    _ = try workspace.run(
                        ["stop", "--name", instance.name], timeout: 60
                    )
                }
                _ = try workspace.run(
                    ["delete", "--name", instance.name], timeout: 120
                )
                DispatchQueue.main.async {
                    self.working = false
                    self.status = "已删除 \(instance.name)"
                    self.refresh()
                }
            } catch {
                DispatchQueue.main.async {
                    self.working = false
                    self.status = "删除失败"
                    self.lastError = error.localizedDescription
                }
            }
        }
    }

    /// "device-1" → "device-2" → "device-3"; "foo" → "foo-1" → "foo-2".
    static func nextCloneName(of name: String, taken: Set<String>) -> String {
        let base: String
        var counter = 1
        if let range = name.range(of: #"-\d+$"#, options: .regularExpression) {
            base = String(name[..<range.lowerBound])
            // The match itself is "-N"; strip the dash for the number.
            counter = (Int(name[range].dropFirst()) ?? 0) + 1
        } else {
            base = name
        }
        var candidate = "\(base)-\(counter)"
        while taken.contains(candidate) {
            counter += 1
            candidate = "\(base)-\(counter)"
        }
        return candidate
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
        onSuccess: ((String) -> Void)? = nil,
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
                    onSuccess?(trimmed)
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
        lines.append("frameMs=\(frameMs) fps=\(frameFps) vncBytes=\(vncBytes)")
        lines.append("frames=" + frames.map { "\($0.key):\(Int($0.value.size.width))x\(Int($0.value.size.height))" }.joined(separator: ","))
        lines.append("displayMode=" + displayMode.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ","))
        lines.append("vncReady=" + vncReady.sorted().joined(separator: ","))
        lines.append("vncFailed=" + vncFailed.sorted().joined(separator: ","))
        lines.append("vncClients=" + vncClients.map {
            "\($0.key)=active:\($0.value.isActive) frames:\($0.value.deliveredFrames) " +
            "enc:" + $0.value.encodingCounts.map { "\($0.key)/\($0.value)" }.sorted().joined(separator: "+")
        }.sorted().joined(separator: " "))
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

/// Device shapes offered by the plus menu, mirroring MuMu's 平板/手机.
enum DevicePreset: String, CaseIterable, Identifiable {
    case tablet
    case phone

    var id: String { rawValue }

    var label: String {
        switch self {
        case .tablet: return "平板"
        case .phone: return "手机"
        }
    }

    var icon: String {
        switch self {
        case .tablet: return "ipad.landscape"
        case .phone: return "iphone"
        }
    }

    var cpus: Int { 4 }
    var memoryMB: Int { 6144 }

    // Tablet mirrors MuMu's default 1600 × 945 @ 236 DPI; phone is a
    // common 1080 × 1920 @ 480 DPI portrait shape.
    var xres: Int {
        switch self {
        case .tablet: return 1600
        case .phone: return 1080
        }
    }

    var yres: Int {
        switch self {
        case .tablet: return 945
        case .phone: return 1920
        }
    }

    var dpi: Int {
        switch self {
        case .tablet: return 236
        case .phone: return 480
        }
    }
}
