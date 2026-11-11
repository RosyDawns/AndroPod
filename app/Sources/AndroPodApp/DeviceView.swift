import AndroPodCore
import SwiftUI

/// View-local state as a reference type.
///
/// `@State` is implemented as a macro in the current SDK, and the macro plugin
/// is not available when building with Command Line Tools only. `@StateObject`
/// is a regular property wrapper, so it works here.
final class DeviceUIState: ObservableObject {
    @Published var isFullScreen = false
    @Published var showControls = true
}

/// The device screen window — mirrors MuMu's in-device view: the Android screen
/// filling the window, with a floating toolbar on the right edge.
struct DeviceView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var ui = DeviceUIState()
    let instance: GuestInstance

    private var running: Bool { model.isRunning(instance) }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            screen
            if running && ui.showControls {
                toolbar.padding(.top, 12).padding(.trailing, 12)
            }
            if !running {
                stoppedOverlay
            }
        }
        .safeAreaInset(edge: .top) {
            if instance.gpuBackend == "virgl" && running {
                // virgl renders into host GPU memory and QEMU presents it in
                // its own cocoa (ANGLE/Metal) window — there is no framebuffer
                // for us to read. A thin status strip beats a second orange
                // warning banner over an otherwise black surface.
                HStack(spacing: 6) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 9, weight: .bold))
                    Text("GPU 直通 · virgl → Metal")
                        .font(.system(size: 10, weight: .medium))
                    Spacer()
                    Button("显示引擎窗口") { activateEngineWindow() }
                        .buttonStyle(.link)
                        .font(.system(size: 10))
                }
                .foregroundStyle(.orange)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Color.orange.opacity(0.12))
            }
        }
        .frame(minWidth: 480, minHeight: 360)
        .background(Color.black)
        .navigationTitle(instance.name)
    }

    private var screen: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                if instance.gpuBackend == "virgl" && running {
                    gpuPanel
                } else if let image = model.frame(for: instance) {
                    Image(nsImage: image)
                        .resizable()
                        // `.high` resamples the full 1280x800 bitmap on every
                        // frame just to scale it down; `.medium` is visually
                        // indistinguishable at this size and much cheaper.
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fit)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { value in
                        guard model.frame(for: instance) != nil else { return }
                        guard let start = guestPoint(value.startLocation, in: geometry.size) else { return }
                        let travel = hypot(
                            value.location.x - value.startLocation.x,
                            value.location.y - value.startLocation.y
                        )
                        if travel < 6 {
                            model.tap(start, on: instance)
                        } else if let end = guestPoint(value.location, in: geometry.size) {
                            model.swipe(from: start, to: end, on: instance)
                        }
                    }
            )
            .overlay(alignment: .bottomLeading) {
                if running {
                    let mode = model.displayMode[instance.name] ?? "screendump"
                    let vnc = mode.hasPrefix("VNC")
                    let label = vnc
                        ? String(format: "%@  %.0f fps  %.1f ms  %.1f MB",
                                 mode, model.frameFps, model.frameMs,
                                 Double(model.vncBytes) / 1024 / 1024)
                        : String(format: "%@  %.1f ms/帧", mode, model.frameMs)
                    Text(label)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.45))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color.black.opacity(0.35))
                        )
                        .padding(8)
                }
            }
        }
    }

    /// virgl has no in-GUI framebuffer. Instead of a black rectangle, show
    /// what is actually happening and the one action that matters: bringing
    /// the engine's own window (where the GPU-rendered frames live) forward.
    private var gpuPanel: some View {
        VStack(spacing: 12) {
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: 38, weight: .thin))
                .foregroundStyle(.orange)
            Text("GPU 直通渲染中")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
            Text("画面由引擎窗口呈现：客机 GLES → Mesa/virgl → 宿主 Metal，\n与 MuMu 走的是同一条路径，帧不进 CPU。")
                .font(.system(size: 11))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Text(instance.resolutionString(live: model.guestSize))
                Text("·")
                Text("\(instance.cpus) 核 / \(instance.memoryMB) MB")
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.white.opacity(0.4))
            Button {
                activateEngineWindow()
            } label: {
                Text("显示引擎窗口")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        }
        .padding(24)
    }

    /// QEMU's cocoa backend runs inside a real NSApplication, so the engine
    /// window can be raised without accessibility permissions — we only need
    /// the pid it wrote at boot.
    private func activateEngineWindow() {
        if !EngineWindow.activate(pidFile: instance.pidFile) {
            model.lastError = "找不到引擎窗口，可能已经退出"
        }
    }

    private var toolbar: some View {
        VStack(spacing: 2) {
            toolButton("chevron.backward", "返回") { model.key("BACK", on: instance) }
            toolButton("circle", "主页") { model.key("HOME", on: instance) }
            Divider().frame(width: 22)
            toolButton("camera", "截图") { model.screenshot(instance) }
            toolButton(ui.isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                       "全屏") {
                ui.isFullScreen.toggle()
                NSApp.keyWindow?.toggleFullScreen(nil)
            }
            toolButton("power", "关机") { model.stop(instance) }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.black.opacity(0.55))
        )
    }

    private func toolButton(_ system: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.9))
        .help(title)
    }

    private var stoppedOverlay: some View {
        VStack(spacing: 10) {
            Image(systemName: "power")
                .font(.system(size: 26, weight: .thin))
            Text("未开机")
                .font(.system(size: 12))
            Button("开机") { model.start(instance) }
                .controlSize(.small)
        }
        .foregroundStyle(.white.opacity(0.5))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Map a point in the view onto guest pixels, accounting for letterboxing.
    private func guestPoint(_ point: CGPoint, in viewSize: CGSize) -> CGPoint? {
        let guest = model.guestSize
        guard guest.width > 0, guest.height > 0, viewSize.width > 0, viewSize.height > 0 else {
            return nil
        }
        let scale = min(viewSize.width / guest.width, viewSize.height / guest.height)
        let originX = (viewSize.width - guest.width * scale) / 2
        let originY = (viewSize.height - guest.height * scale) / 2
        let x = (point.x - originX) / scale
        let y = (point.y - originY) / scale
        guard x >= 0, y >= 0, x <= guest.width, y <= guest.height else { return nil }
        return CGPoint(x: x.rounded(), y: y.rounded())
    }
}

/// Owns one window per device, so double-clicking a card behaves like MuMu.
@MainActor
final class DeviceWindowController {
    static let shared = DeviceWindowController()
    private var windows: [String: NSWindow] = [:]
    /// willClose observer tokens, keyed by instance name. The token MUST be
    /// kept alive: the block-based addObserver API unregisters when the token
    /// deallocates, and a half-registered observer whose token is gone is
    /// exactly the crash we saw on window close.
    private var closeObservers: [String: NSObjectProtocol] = [:]

    func show(_ instance: GuestInstance, model: AppModel) {
        if let existing = windows[instance.name] {
            existing.makeKeyAndOrderFront(nil)
            model.focus(instance.name)
            return
        }

        let root = DeviceView(instance: instance).environmentObject(model)
        let hosting = KeyForwardingHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: 860, height: 620)
        // Raw keyboard → QEMU qcodes via the QMP input socket. adb is NOT in
        // this path on purpose: the boot menu (GRUB) runs long before adbd,
        // and virtio-keyboard delivers to both GRUB and Android alike.
        hosting.onQcode = { [weak model] qcode in
            guard let model else { return }
            model.key(qcode, on: instance)
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        // Default is true: AppKit releases the window during the close flow,
        // leaving our dictionary entry dangling — the later removeValue in the
        // willClose handler then over-releases it (SIGSEGV in objc_release,
        // the crash on clicking the traffic-light close button).
        window.isReleasedWhenClosed = false
        window.title = instance.name
        window.contentView = hosting
        window.minSize = NSSize(width: 480, height: 360)
        window.setContentSize(NSSize(width: 860, height: 620))
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(hosting)
        windows[instance.name] = window

        // Only the visible device streams at full rate; everything else idles
        // at thumbnail cadence so we do not steal guest CPU for invisible frames.
        model.focus(instance.name)

        closeObservers[instance.name] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.windows.removeValue(forKey: instance.name)
                if let observer = self.closeObservers.removeValue(forKey: instance.name) {
                    NotificationCenter.default.removeObserver(observer)
                }
                model.focus(nil)
                // MuMu behaviour: closing the device window powers the guest
                // off. Otherwise the card keeps showing "running" and the user
                // has to click stop a second time.
                if model.isRunning(instance) {
                    model.stop(instance)
                }
            }
        }
    }
}

/// NSHostingView that forwards raw keyboard events to the guest as QEMU
/// qcodes over the QMP input socket.
///
/// Why QMP and not adb: the boot menu (GRUB) runs before adbd exists, and
/// virtio-keyboard delivers to the bootloader and Android alike — one path
/// covers both. Mouse/touch keep using the QMP pointer path wired in
/// DeviceView; keys were the missing half of the input story.
final class KeyForwardingHostingView<Content: View>: NSHostingView<Content> {
    /// Called with a QEMU qcode name, e.g. "up", "ret", "esc".
    var onQcode: ((String) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if let qcode = Self.qcode(for: event) {
            onQcode?(qcode)
            return
        }
        // Unmapped keys (input sources, media keys…) fall through to the
        // normal responder chain so shortcuts like Cmd+W keep working.
        super.keyDown(with: event)
    }

    /// macOS virtual key codes → QEMU qcodes. Deliberately small: the boot
    /// menu needs arrows/enter/esc; Android adds typing keys.
    static func qcode(for event: NSEvent) -> String? {
        let special: [UInt16: String] = [
            123: "left", 124: "right", 125: "down", 126: "up",
            36: "ret", 76: "kp_enter",
            53: "esc",
            51: "backspace", 117: "delete",
            115: "home", 119: "end", 116: "pgup", 121: "pgdn",
            48: "tab", 49: "spc",
            56: "shift", 60: "shift_r",
            58: "alt", 61: "alt_r",
            59: "ctrl", 62: "ctrl_r",
            55: "meta_l", 54: "meta_r",
            122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6",
            98: "f7", 100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12",
        ]
        if let qcode = special[event.keyCode] { return qcode }

        if (65...90).contains(event.keyCode) {
            return String(UnicodeScalar(UInt8(event.keyCode - 65 + 97)))
        }
        // Top-row digits (kVK_ANSI_0 .. kVK_ANSI_9 are not contiguous).
        let digits: [UInt16: String] = [
            29: "0", 18: "1", 19: "2", 20: "3", 21: "4",
            23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
        ]
        return digits[event.keyCode]
    }
}
