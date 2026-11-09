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
        .frame(minWidth: 480, minHeight: 360)
        .background(Color.black)
        .navigationTitle(instance.name)
    }

    private var screen: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                if let image = model.frame(for: instance) {
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
                    Text(String(format: "%.1f ms/帧", model.frameMs))
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

    func show(_ instance: GuestInstance, model: AppModel) {
        if let existing = windows[instance.name] {
            existing.makeKeyAndOrderFront(nil)
            model.focus(instance.name)
            return
        }

        let root = DeviceView(instance: instance).environmentObject(model)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: 860, height: 620)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = instance.name
        window.contentView = hosting
        window.minSize = NSSize(width: 480, height: 360)
        window.setContentSize(NSSize(width: 860, height: 620))
        window.center()
        window.makeKeyAndOrderFront(nil)
        windows[instance.name] = window

        // Only the visible device streams at full rate; everything else idles
        // at thumbnail cadence so we do not steal guest CPU for invisible frames.
        model.focus(instance.name)

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.windows.removeValue(forKey: instance.name)
                model.focus(nil)
            }
        }
    }
}
