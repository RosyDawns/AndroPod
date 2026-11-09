import Foundation

/// Injects pointer and key events straight into QEMU over a dedicated QMP
/// socket, so a tap costs a single write instead of a process launch.
///
/// This exists because of a measurement: routing a tap through the Python CLI
/// took 410 ms at best and 30 s once the device got into a bad state, while a
/// raw `input-send-event` on a warm socket is sub-millisecond. Anything that
/// makes the screen feel laggy is fatal for a device emulator, so the UI does
/// not shell out for input.
///
/// It also deliberately avoids adb. Restoring a snapshot rewinds the guest but
/// not the host-side TCP proxy, which leaves adbd holding a socket that no
/// longer exists — after every snapshot boot, `adb shell` hangs until it times
/// out. QMP is the only input channel that survives that.
public final class InputClient {
    /// Guest pixel coordinate space. QEMU's absolute pointer speaks 0..32767.
    public struct Screen {
        public let width: Int
        public let height: Int
        public init(width: Int = 1280, height: Int = 800) {
            self.width = width
            self.height = height
        }
    }

    private let socketPath: String
    private let queue = DispatchQueue(label: "com.andropod.input", qos: .userInteractive)
    private var client: QMPClient?
    public var screen = Screen()
    public var onError: ((String) -> Void)?

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    // MARK: - events

    /// A touch-down, short hold, and release at one point.
    ///
    /// Two round trips, not three: the position and the press go out together,
    /// then only the release is separate. Sending press and release in the same
    /// batch still gets dropped by Android's input pipeline, but the position
    /// can ride along with the press — earlier versions split all three and paid
    /// an extra millisecond of latency for nothing.
    public func tap(x: Int, y: Int, holdMs: Int = 18) {
        let scaled = scale(x: x, y: y)
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let c = try self.warmClient()
                try c.execute("input-send-event", arguments: [
                    "events": [
                        ["type": "abs", "data": ["axis": "x", "value": scaled.x]],
                        ["type": "abs", "data": ["axis": "y", "value": scaled.y]],
                        ["type": "btn", "data": ["down": true, "button": "left"]],
                    ],
                ])
                Thread.sleep(forTimeInterval: Double(holdMs) / 1000)
                try c.execute("input-send-event", arguments: [
                    "events": [["type": "btn", "data": ["down": false, "button": "left"]]],
                ])
            } catch {
                self.handle(error)
            }
        }
    }

    /// Press, drag through interpolated points, release.
    ///
    /// Intermediate points matter: a single jump from start to end registers as
    /// a fling or as nothing at all, depending on the widget's velocity tracker.
    public func swipe(from: CGPoint, to: CGPoint, durationMs: Int = 260) {
        let start = scale(x: Int(from.x), y: Int(from.y))
        let end = scale(x: Int(to.x), y: Int(to.y))
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let c = try self.warmClient()
                try c.execute("input-send-event", arguments: [
                    "events": [
                        ["type": "abs", "data": ["axis": "x", "value": start.x]],
                        ["type": "abs", "data": ["axis": "y", "value": start.y]],
                    ],
                ])
                try c.execute("input-send-event", arguments: [
                    "events": [["type": "btn", "data": ["down": true, "button": "left"]]],
                ])

                let steps = max(6, durationMs / 16)
                for i in 1...steps {
                    let t = Double(i) / Double(steps)
                    // Ease-out: fast launch, gentle settle, like a finger flick.
                    let eased = 1 - pow(1 - t, 2)
                    let px = Int(Double(start.x) + (Double(end.x) - Double(start.x)) * eased)
                    let py = Int(Double(start.y) + (Double(end.y) - Double(start.y)) * eased)
                    try c.execute("input-send-event", arguments: [
                        "events": [
                            ["type": "abs", "data": ["axis": "x", "value": px]],
                            ["type": "abs", "data": ["axis": "y", "value": py]],
                        ],
                    ])
                    Thread.sleep(forTimeInterval: Double(durationMs) / 1000 / Double(steps))
                }

                try c.execute("input-send-event", arguments: [
                    "events": [["type": "btn", "data": ["down": false, "button": "left"]]],
                ])
            } catch {
                self.handle(error)
            }
        }
    }

    /// Sends a key by QEMU qcode name (`home`, `back`, `ret`, `esc`...).
    public func key(_ qcode: String) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let c = try self.warmClient()
                try c.execute("input-send-event", arguments: [
                    "events": [
                        ["type": "key", "data": ["down": true, "key": ["type": "qcode", "data": qcode]]],
                    ],
                ])
                Thread.sleep(forTimeInterval: 0.02)
                try c.execute("input-send-event", arguments: [
                    "events": [
                        ["type": "key", "data": ["down": false, "key": ["type": "qcode", "data": qcode]]],
                    ],
                ])
            } catch {
                self.handle(error)
            }
        }
    }

    public func disconnect() {
        queue.async { [weak self] in
            self?.client?.close()
            self?.client = nil
        }
    }

    // MARK: - plumbing

    private func scale(x: Int, y: Int) -> (x: Int, y: Int) {
        let w = max(screen.width, 1)
        let h = max(screen.height, 1)
        let cx = min(max(x, 0), w - 1)
        let cy = min(max(y, 0), h - 1)
        return (Int(Double(cx) / Double(w) * 32767), Int(Double(cy) / Double(h) * 32767))
    }

    private func warmClient() throws -> QMPClient {
        if let client, client.isConnected { return client }
        let fresh = QMPClient()
        try fresh.connect(unixPath: socketPath, timeout: 2)
        client = fresh
        return fresh
    }

    private func handle(_ error: Error) {
        client?.close()
        client = nil
        let message = error.localizedDescription
        DispatchQueue.main.async { [weak self] in self?.onError?(message) }
    }
}
