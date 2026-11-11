// Headless verification of the Swift RFB client.
//
// Build (from the project root):
//   swiftc -O -parse-as-library -o /tmp/vncverify \
//     app/Sources/AndroPodCore/VNCClient.swift scripts/VNCVerify.swift
//   /tmp/vncverify 5901 /tmp/vt/swift_frame.png
//
// It connects, waits for real FramebufferUpdate frames, writes the last one as
// PNG, and prints the observed frame size / build cost / bytes received.
// This exists because the GUI has historically been a poor oracle: a blank
// window can mean a dozen unrelated things, while a PNG can be inspected.

import AppKit
import Foundation

@main
enum VNCVerify {
    static func writePNG(_ image: NSImage, to path: String) -> Bool {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            return false
        }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }

    static func main() {
        let port = CommandLine.arguments.count > 1
            ? Int(CommandLine.arguments[1]) ?? 5901 : 5901
        let out = CommandLine.arguments.count > 2
            ? CommandLine.arguments[2] : "/tmp/andropod-vnc.png"
        let targetFrames = CommandLine.arguments.count > 3
            ? Int(CommandLine.arguments[3]) ?? 4 : 4

        let client = VNCClient(port: port)
        let semaphore = DispatchSemaphore(value: 0)
        let stateLock = NSLock()
        let box = State()

        client.callbackQueue = DispatchQueue(label: "verify.callback", qos: .userInitiated)
        client.onFrame = { image in
            stateLock.lock()
            box.frames += 1
            box.lastImage = image
            let n = box.frames
            stateLock.unlock()
            if n >= targetFrames { semaphore.signal() }
        }
        client.onStats = { ms, fps, bytes, _ in
            stateLock.lock()
            box.lastStats = String(format: "%.2f ms build, %.1f fps, %.1f MB received",
                                   ms, fps, Double(bytes) / 1024 / 1024)
            stateLock.unlock()
        }
        client.onFailure = { error in
            stateLock.lock()
            box.failure = error.localizedDescription
            stateLock.unlock()
            semaphore.signal()
        }

        print("连接 VNC 127.0.0.1:\(port) …")
        client.start()
        let timedOut = semaphore.wait(timeout: .now() + 25) == .timedOut
        client.stop()

        stateLock.lock()
        let n = box.frames
        let image = box.lastImage
        let stats = box.lastStats
        let err = box.failure
        stateLock.unlock()

        if let err {
            print("[FAIL] \(err)")
            exit(1)
        }
        if let image {
            let ok = writePNG(image, to: out)
            print("[PASS] 收到 \(n) 帧，画面 \(Int(image.size.width))x\(Int(image.size.height))")
            print("       \(stats)")
            let names: [Int32: String] = [0: "Raw", 1: "CopyRect", 16: "ZRLE", -223: "DesktopSize"]
            let counts = client.encodingCounts
                .map { "\(names[$0.key] ?? "\($0.key)")=\($0.value)" }
                .sorted().joined(separator: " ")
            print("       矩形编码: \(counts.isEmpty ? "(无)" : counts)")
            print("       PNG \(ok ? "已写入" : "写入失败") \(out)")
            if timedOut { print("       （等待更多帧超时，但已有真实画面）") }
            exit(ok ? 0 : 1)
        }
        print("[FAIL] 没有收到任何帧\(timedOut ? "（超时）" : "")")
        exit(1)
    }
}

/// Mutable results shared with the callback queue. A class keeps them in one
/// place so the lock covers every field without capturing `inout` locals.
private final class State {
    var frames = 0
    var lastImage: NSImage?
    var lastStats = ""
    var failure: String?
}
