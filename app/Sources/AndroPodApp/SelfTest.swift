import AndroPodCore
import AppKit
import Foundation

/// Non-interactive verification of the parts of the app that can silently break:
/// project discovery, instance scanning, and the QMP frame pipeline.
/// Run with `AndroPod --self-test`.
enum SelfTest {
    static func run() -> Int32 {
        print("AndroPod 自检")
        var failures = 0

        guard let root = ProjectRoot.locate() else {
            print("  [FAIL] 找不到项目根目录（需要包含 bin/andropod）")
            return 1
        }
        print("  [PASS] 项目根 \(root.path)")

        let workspace = Workspace(root: root)
        let instances = workspace.loadInstances()
        print("  [PASS] 发现实例 \(instances.count) 个：\(instances.map(\.name).joined(separator: ", "))")

        let running = instances.filter { workspace.isRunning($0) }
        if running.isEmpty {
            print("  [INFO] 当前没有运行中的实例，跳过抓帧测试")
        }

        for instance in running {
            print("  实例 \(instance.name)：")

            // The fast display path. A headless client that receives real
            // frames proves the RFB handshake, the shared zlib stream and the
            // ZRLE tile decoder all work without needing a window.
            if let port = instance.vncPort {
                let vnc = VNCClient(port: port)
                let done = DispatchSemaphore(value: 0)
                let results = VNCProbe()
                vnc.callbackQueue = DispatchQueue(label: "selftest.vnc", qos: .userInitiated)
                vnc.onFrame = { image in
                    results.images += 1
                    results.size = image.size
                    if results.images >= 2 { done.signal() }
                }
                vnc.onFailure = { error in
                    results.error = error.localizedDescription
                    done.signal()
                }
                vnc.start()
                let timedOut = done.wait(timeout: .now() + 10) == .timedOut
                let counts = vnc.encodingCounts
                let size = results.size
                let error = results.error
                let images = results.images
                vnc.stop()
                if let error {
                    print("    [FAIL] VNC 127.0.0.1:\(port)：\(error)")
                    failures += 1
                } else if images == 0 {
                    print("    [FAIL] VNC 127.0.0.1:\(port) 没有收到帧")
                    failures += 1
                } else {
                    let codecs = counts.map { "\($0.key):\($0.value)" }.sorted().joined(separator: ",")
                    print("    [PASS] VNC \(port)：\(images) 帧 \(Int(size.width))x\(Int(size.height))，编码矩形 \(codecs)")
                    if timedOut { print("    [INFO] 第 2 帧等待超时（静态画面只推一次，属正常）") }
                }
            } else {
                print("    [INFO] 未配置 VNC，GUI 将使用 screendump")
            }

            let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("andropod-selftest-\(instance.name).ppm")
            let client = QMPClient()
            do {
                try client.connect(unixPath: instance.displaySocket.path, timeout: 3)
                print("    [PASS] 显示通道连接成功，状态 \(try client.status())")

                // Warm up: the first dump pays page-fault and socket costs that
                // would skew the average.
                try client.execute("screendump", arguments: ["filename": scratch.path])

                let samples = 30
                var captureMs: [Double] = []
                var decodeMs: [Double] = []
                var lastImage: NSImage?
                for _ in 0..<samples {
                    let t0 = Date()
                    try client.execute("screendump", arguments: ["filename": scratch.path])
                    let t1 = Date()
                    guard let data = try? Data(contentsOf: scratch, options: .mappedIfSafe),
                          let cgImage = PPMDecoder.decode(data)
                    else {
                        print("    [FAIL] 帧图像无法解析")
                        failures += 1
                        break
                    }
                    lastImage = NSImage(
                        cgImage: cgImage,
                        size: NSSize(width: cgImage.width, height: cgImage.height)
                    )
                    let t2 = Date()
                    captureMs.append(t1.timeIntervalSince(t0) * 1000)
                    decodeMs.append(t2.timeIntervalSince(t1) * 1000)
                }

                func stats(_ xs: [Double]) -> (Double, Double, Double) {
                    let sorted = xs.sorted()
                    let mean = xs.reduce(0, +) / Double(max(xs.count, 1))
                    let median = sorted[sorted.count / 2]
                    return (mean, median, sorted.first ?? 0)
                }

                let capture = stats(captureMs)
                let decode = stats(decodeMs)
                let total = capture.0 + decode.0
                print(String(format: "    [PASS] 抓帧 %.1f ms（中位 %.1f，最快 %.1f）",
                             capture.0, capture.1, capture.2))
                print(String(format: "    [PASS] 解码 %.1f ms（中位 %.1f，最快 %.1f）",
                             decode.0, decode.1, decode.2))
                print(String(format: "    [INFO] 端到端 %.1f ms/帧 → 上限 %.0f fps", total, 1000 / total))

                if let lastImage {
                    print("    [PASS] 画面 \(Int(lastImage.size.width))x\(Int(lastImage.size.height))")
                }
                if total > 33 {
                    print("    [WARN] 单帧超过 33 ms，30 fps 下会掉帧")
                }
                client.close()
            } catch {
                print("    [FAIL] \(error.localizedDescription)")
                print("    （显示通道一次只接受一个客户端；若 GUI 正在运行，通道已被它占用）")
                failures += 1
                client.close()
            }
        }

        print(failures == 0 ? "自检通过" : "自检失败 \(failures) 项")
        return failures == 0 ? 0 : 1
    }
}

/// Result holder for the asynchronous VNC probe above.
private final class VNCProbe {
    var images = 0
    var size = NSSize.zero
    var error: String?
}
