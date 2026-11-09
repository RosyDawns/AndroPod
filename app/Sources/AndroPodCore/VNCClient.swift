import AppKit
import Darwin
import Foundation
import zlib

/// A small RFB 3.8 client for QEMU's built-in VNC server.
///
/// Why this exists
/// ---------------
/// `FramePoller` asks QEMU for a full-screen `screendump` on a timer. That
/// always copies 3 MB even when nothing changed, and each dump executes inside
/// QEMU's main loop, competing with the guest for CPU. Measured with the guest
/// actively scrolling:
///
///   screendump PPM   30 fps x 3 MB (full frame, always)   ~90 MB/s
///   VNC Raw          incremental dirty rects              ~2.2 MB/s
///   VNC ZRLE         incremental + compressed             ~0.38 MB/s
///
/// VNC is push-based: QEMU only sends rectangles whose contents changed, and
/// the client asks for the next update only after consuming the previous one.
/// An idle screen therefore costs essentially nothing, and there is no 60 Hz
/// polling loop on the host at all.
///
/// Protocol facts verified against this QEMU build (see scripts/):
///  - QEMU picks the FIRST encoding the client advertises. ZRLE must lead.
///  - ZRLE uses ONE zlib stream for the entire connection. Each rectangle is
///    a Z_SYNC_FLUSH-ed chunk, so resetting inflate per rectangle fails with
///    "incomplete or truncated stream". A persistent `z_stream` is required.
///  - With bpp=32/depth=24/max=255 the 3-byte CPIXEL keeps the low three
///    bytes. With blue-shift=0 those are already B,G,R, so they copy straight
///    into a BGRA framebuffer. Treating them as R,G,B swaps red and blue —
///    the reference decoder matched only 4/704 pixels before this was fixed,
///    and 704/704 after.
///  - QEMU sends 32bpp little-endian BGRA on the wire for Raw rectangles.
///
/// This file speaks RFB only. It does not link QEMU, preserving the license
/// boundary described in docs/01-license-boundary.md.
public final class VNCClient {
    public enum ClientError: LocalizedError {
        case socket(String)
        case handshake(String)
        case protocolViolation(String)
        case decode(String)
        case closed

        public var errorDescription: String? {
            switch self {
            case .socket(let d): return "VNC 连接失败：\(d)"
            case .handshake(let d): return "VNC 握手失败：\(d)"
            case .protocolViolation(let d): return "VNC 协议异常：\(d)"
            case .decode(let d): return "VNC 解码失败：\(d)"
            case .closed: return "VNC 连接已关闭"
            }
        }
    }

    /// Called on the main queue with a fully composited frame.
    public var onFrame: ((NSImage) -> Void)?
    /// (frame build milliseconds, frames per second, bytes received, dirty rects)
    public var onStats: ((Double, Double, Int, Int) -> Void)?
    /// A fatal transport/decode error. The caller should fall back to screendump.
    public var onFailure: ((Error) -> Void)?

    public private(set) var isActive = false
    public private(set) var frameWidth = 0
    public private(set) var frameHeight = 0
    /// Bumped every time a full frame is published; useful for headless tests.
    public private(set) var deliveredFrames = 0

    private let host: String
    private let port: Int
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var stopped = true

    /// BGRA8888, row-major, `frameWidth * frameHeight * 4` bytes.
    private var framebuffer = [UInt8]()
    private var inflater = ZRLEInflater()
    private var readBuffer = [UInt8]()
    private var readOffset = 0

    private var bytesReceived = 0
    private var frameCount = 0
    private var statsEpoch = CFAbsoluteTimeGetCurrent()

    // RFB encoding numbers.
    private static let encRaw: Int32 = 0
    private static let encCopyRect: Int32 = 1
    private static let encZRLE: Int32 = 16
    private static let encDesktopSize: Int32 = -223

    public init(host: String = "127.0.0.1", port: Int) {
        self.host = host
        self.port = port
        self.queue = DispatchQueue(
            label: "com.andropod.vnc.\(host):\(port)",
            qos: .userInitiated
        )
    }

    deinit { shutdownSocket() }

    // MARK: - lifecycle

    public func start() {
        lock.lock()
        if !stopped { lock.unlock(); return }
        stopped = false
        lock.unlock()

        queue.async { [weak self] in self?.run() }
    }

    public func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        shutdownSocket()
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func shutdownSocket() {
        lock.lock()
        let fd = descriptor
        descriptor = -1
        lock.unlock()
        guard fd >= 0 else { return }
        // shutdown wakes a blocking recv, so stop() never waits for the next
        // server update (which may be seconds away on an idle screen).
        Darwin.shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }

    // MARK: - socket

    private func connect() throws {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var info: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &info)
        guard rc == 0, let info else {
            throw ClientError.socket("无法解析 \(host):\(port)（\(String(cString: gai_strerror(rc)))）")
        }
        defer { freeaddrinfo(info) }

        let fd = Darwin.socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        guard fd >= 0 else {
            throw ClientError.socket(String(cString: strerror(errno)))
        }

        // Bounded connect: a QEMU instance without -vnc must fail fast so the
        // UI can fall back to screendump instead of hanging on refresh.
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var readTimeout = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &readTimeout, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))

        let result = Darwin.connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen)
        guard result == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(fd)
            throw ClientError.socket(message)
        }

        lock.lock()
        descriptor = fd
        lock.unlock()
        readBuffer.removeAll(keepingCapacity: true)
        readOffset = 0
    }

    private func currentDescriptor() -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        return descriptor
    }

    /// Reads exactly `count` bytes. RFB messages are length-prefixed, so a
    /// short read must never be mistaken for a complete rectangle.
    private func readExactly(_ count: Int) throws -> [UInt8] {
        guard count >= 0 else { throw ClientError.protocolViolation("负长度 \(count)") }
        if count == 0 { return [] }
        var out = [UInt8]()
        out.reserveCapacity(count)

        while out.count < count {
            if readOffset < readBuffer.count {
                let available = min(count - out.count, readBuffer.count - readOffset)
                out.append(contentsOf: readBuffer[readOffset..<(readOffset + available)])
                readOffset += available
                continue
            }
            let fd = currentDescriptor()
            guard fd >= 0 else { throw ClientError.closed }
            var chunk = [UInt8](repeating: 0, count: min(1 << 16, max(count - out.count, 4096)))
            let n = chunk.withUnsafeMutableBytes { raw in
                Darwin.recv(fd, raw.baseAddress, raw.count, 0)
            }
            if n > 0 {
                readBuffer = Array(chunk[0..<n])
                readOffset = 0
            } else if n == 0 {
                throw ClientError.closed
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                if isStopped { throw ClientError.closed }
                continue
            } else {
                throw ClientError.socket(String(cString: strerror(errno)))
            }
        }
        bytesReceived += count
        return out
    }

    private func send(_ bytes: [UInt8]) throws {
        let fd = currentDescriptor()
        guard fd >= 0 else { throw ClientError.closed }
        try bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                if written > 0 {
                    offset += written
                } else if errno == EAGAIN || errno == EWOULDBLOCK {
                    continue
                } else {
                    throw ClientError.socket(String(cString: strerror(errno)))
                }
            }
        }
    }

    // MARK: - big-endian helpers

    private static func u16(_ b: [UInt8], _ i: Int) -> Int {
        (Int(b[i]) << 8) | Int(b[i + 1])
    }

    private static func u32(_ b: [UInt8], _ i: Int) -> Int {
        (Int(b[i]) << 24) | (Int(b[i + 1]) << 16) | (Int(b[i + 2]) << 8) | Int(b[i + 3])
    }

    private static func i32(_ b: [UInt8], _ i: Int) -> Int32 {
        Int32(bitPattern: UInt32(u32(b, i)))
    }

    private static func appendU16(_ out: inout [UInt8], _ v: Int) {
        out.append(UInt8(truncatingIfNeeded: v >> 8))
        out.append(UInt8(truncatingIfNeeded: v))
    }

    private static func appendU32(_ out: inout [UInt8], _ v: UInt32) {
        out.append(UInt8(truncatingIfNeeded: v >> 24))
        out.append(UInt8(truncatingIfNeeded: v >> 16))
        out.append(UInt8(truncatingIfNeeded: v >> 8))
        out.append(UInt8(truncatingIfNeeded: v))
    }

    // MARK: - handshake

    private func handshake() throws -> (Int, Int) {
        let version = try readExactly(12)
        guard let text = String(bytes: version, encoding: .utf8),
              text.hasPrefix("RFB 003.") else {
            throw ClientError.handshake("不是 RFB 3.x 服务：\(String(decoding: version, as: UTF8.self))")
        }
        try send(Array("RFB 003.008\n".utf8))

        let count = Int(try readExactly(1)[0])
        if count == 0 {
            let length = Self.u32(try readExactly(4), 0)
            let reason = String(decoding: try readExactly(length), as: UTF8.self)
            throw ClientError.handshake(reason)
        }
        let types = try readExactly(count)
        guard types.contains(1) else {
            throw ClientError.handshake("服务端不支持 SecurityType None（类型 \(types.map(String.init).joined(separator: ","))）")
        }
        try send([1])
        let result = Self.u32(try readExactly(4), 0)
        guard result == 0 else { throw ClientError.handshake("SecurityResult=\(result)") }

        try send([1])  // ClientInit: shared

        let head = try readExactly(24)
        let width = Self.u16(head, 0)
        let height = Self.u16(head, 2)
        guard width > 0, height > 0, width <= 8192, height <= 8192 else {
            throw ClientError.handshake("画面尺寸异常 \(width)x\(height)")
        }
        let nameLength = Self.u32(head, 20)
        if nameLength > 0 { _ = try readExactly(nameLength) }

        // Fix the pixel format explicitly rather than trusting ServerInit.
        // 32bpp/24depth/true-colour, little endian, BGRA byte order in memory.
        // This is also what makes ZRLE use the compact 3-byte CPIXEL.
        var pf: [UInt8] = [0, 0, 0, 0]  // SetPixelFormat + 3 bytes padding
        pf += [32, 24, 0, 1,            // bpp, depth, big-endian, true-colour
               0, 255, 0, 255, 0, 255,  // red/green/blue max (big endian)
               16, 8, 0,                // shifts: 32-bit value is 0x00RRGGBB
               0, 0, 0]                // padding
        try send(pf)

        // QEMU selects the FIRST advertised encoding, so ZRLE must lead.
        // CopyRect and Raw are fallbacks; DesktopSize handles rotation/resize.
        let encodings: [Int32] = [Self.encZRLE, Self.encCopyRect,
                                  Self.encRaw, Self.encDesktopSize]
        var msg: [UInt8] = [2, 0]
        Self.appendU16(&msg, encodings.count)
        for e in encodings { Self.appendU32(&msg, UInt32(bitPattern: e)) }
        try send(msg)

        allocateFramebuffer(width: width, height: height)
        try requestUpdate(incremental: false)
        return (width, height)
    }

    private func allocateFramebuffer(width: Int, height: Int) {
        frameWidth = width
        frameHeight = height
        // Opaque black initially; alpha=255 everywhere so CGImage needs no
        // per-pixel alpha handling on later updates.
        framebuffer = [UInt8](repeating: 0, count: width * height * 4)
        for i in stride(from: 3, to: framebuffer.count, by: 4) {
            framebuffer[i] = 255
        }
    }

    private func requestUpdate(incremental: Bool) throws {
        var msg: [UInt8] = [3, incremental ? 1 : 0]
        Self.appendU16(&msg, 0)
        Self.appendU16(&msg, 0)
        Self.appendU16(&msg, frameWidth)
        Self.appendU16(&msg, frameHeight)
        try send(msg)
    }

    // MARK: - receive loop

    private func run() {
        do {
            try connect()
            let size = try handshake()
            isActive = true
            statsEpoch = CFAbsoluteTimeGetCurrent()
            publish(size: size, rebuild: true)
            try receiveLoop()
        } catch {
            isActive = false
            if !isStopped {
                DispatchQueue.main.async { [weak self] in self?.onFailure?(error) }
            }
        }
        shutdownSocket()
        isActive = false
    }

    private func receiveLoop() throws {
        while !isStopped {
            let kind = try readExactly(1)[0]
            switch kind {
            case 0:   // FramebufferUpdate
                _ = try readExactly(1)  // padding
                let rectCount = Self.u16(try readExactly(2), 0)
                var dirty = 0
                var resized = false
                for _ in 0..<rectCount {
                    let header = try readExactly(12)
                    let x = Self.u16(header, 0)
                    let y = Self.u16(header, 2)
                    let w = Self.u16(header, 4)
                    let h = Self.u16(header, 6)
                    let encoding = Self.i32(header, 8)
                    if try applyRect(x: x, y: y, width: w, height: h, encoding: encoding) {
                        resized = true
                    }
                    dirty += 1
                }
                if dirty > 0 && !resized {
                    publish(size: (frameWidth, frameHeight), rebuild: false)
                }
                // Ask for the next change only after consuming this one. This
                // is the back-pressure that replaces the 60 Hz host timer.
                try requestUpdate(incremental: true)
            case 1:   // SetColourMapEntries
                _ = try readExactly(3)
                let n = Self.u16(try readExactly(2), 0)
                _ = try readExactly(n * 6)
            case 2:   // Bell
                break
            case 3:   // ServerCutText
                _ = try readExactly(3)
                let n = Self.u32(try readExactly(4), 0)
                _ = try readExactly(n)
            default:
                throw ClientError.protocolViolation("未知服务端消息类型 \(kind)")
            }
        }
    }

    /// Returns true when the rectangle was a DesktopSize pseudo-encoding.
    private func applyRect(x: Int, y: Int, width: Int, height: Int, encoding: Int32) throws -> Bool {
        switch encoding {
        case Self.encRaw:
            let bytes = try readExactly(width * height * 4)
            try blit(bytes, x: x, y: y, width: width, height: height, bytesPerPixel: 4)
        case Self.encCopyRect:
            let src = try readExactly(4)
            try copyRect(srcX: Self.u16(src, 0), srcY: Self.u16(src, 2),
                         x: x, y: y, width: width, height: height)
        case Self.encZRLE:
            let length = Self.u32(try readExactly(4), 0)
            let compressed = try readExactly(length)
            let expanded = try inflater.decode(compressed)
            try decodeZRLE(expanded, x: x, y: y, width: width, height: height)
        case Self.encDesktopSize:
            allocateFramebuffer(width: width, height: height)
            inflater = ZRLEInflater()
            try requestUpdate(incremental: false)
            return true
        default:
            throw ClientError.decode("未支持的编码 \(encoding)")
        }
        return false
    }

    // MARK: - rectangle decoding

    private func blit(_ bytes: [UInt8], x: Int, y: Int, width: Int, height: Int,
                      bytesPerPixel: Int) throws {
        guard x >= 0, y >= 0, x + width <= frameWidth, y + height <= frameHeight else {
            throw ClientError.decode("矩形越界 (\(x),\(y) \(width)x\(height)) / \(frameWidth)x\(frameHeight)")
        }
        let rowBytes = width * bytesPerPixel
        guard bytes.count >= rowBytes * height else {
            throw ClientError.decode("Raw 数据不足：\(bytes.count) < \(rowBytes * height)")
        }
        let fbRow = frameWidth * 4
        for row in 0..<height {
            let from = row * rowBytes
            let to = (y + row) * fbRow + x * 4
            for i in 0..<rowBytes {
                framebuffer[to + i] = bytes[from + i]
            }
        }
    }

    /// CopyRect reads from the framebuffer itself and may overlap its target,
    /// so stage the source rows before writing to avoid smearing.
    private func copyRect(srcX: Int, srcY: Int, x: Int, y: Int, width: Int, height: Int) throws {
        guard srcX >= 0, srcY >= 0, srcX + width <= frameWidth, srcY + height <= frameHeight,
              x >= 0, y >= 0, x + width <= frameWidth, y + height <= frameHeight else {
            throw ClientError.decode("CopyRect 越界")
        }
        let fbRow = frameWidth * 4
        var staged = [[UInt8]]()
        staged.reserveCapacity(height)
        for row in 0..<height {
            let from = (srcY + row) * fbRow + srcX * 4
            staged.append(Array(framebuffer[from..<(from + width * 4)]))
        }
        for row in 0..<height {
            let to = (y + row) * fbRow + x * 4
            for i in 0..<(width * 4) {
                framebuffer[to + i] = staged[row][i]
            }
        }
    }

    /// Decodes one ZRLE rectangle's expanded tile stream.
    ///
    /// Tiles are 64x64 in raster order, truncated at the rectangle edges. Each
    /// starts with one subencoding byte:
    ///   0            raw CPIXELs
    ///   1            one solid CPIXEL
    ///   2...16       packed palette (1/2/4 bits per index, row-aligned)
    ///   128          plain RLE (CPIXEL + run length)
    ///   130...255    palette RLE (palette, then index/length runs)
    /// CPIXEL is 3 bytes here and, with blue-shift=0, is already B,G,R.
    private func decodeZRLE(_ data: [UInt8], x: Int, y: Int, width: Int, height: Int) throws {
        guard x >= 0, y >= 0, x + width <= frameWidth, y + height <= frameHeight else {
            throw ClientError.decode("ZRLE 矩形越界")
        }
        var pos = 0
        let count = data.count
        let fbRow = frameWidth * 4

        func need(_ n: Int) throws {
            guard pos + n <= count else {
                throw ClientError.decode("ZRLE 数据提前结束（需要 \(n) 字节，pos=\(pos)/\(count)）")
            }
        }

        func cpixel() throws -> (UInt8, UInt8, UInt8) {
            try need(3)
            let p = (data[pos], data[pos + 1], data[pos + 2])
            pos += 3
            return p
        }

        /// RFB run length: sum bytes until one is not 255, then add 1.
        func runLength() throws -> Int {
            var total = 1
            while true {
                try need(1)
                let b = Int(data[pos])
                pos += 1
                total += b
                if b != 255 { break }
            }
            return total
        }

        func write(_ p: (UInt8, UInt8, UInt8), gx: Int, gy: Int) {
            let off = gy * fbRow + gx * 4
            framebuffer[off] = p.0
            framebuffer[off + 1] = p.1
            framebuffer[off + 2] = p.2
            framebuffer[off + 3] = 255
        }

        var tileY = 0
        while tileY < height {
            var tileX = 0
            while tileX < width {
                let tw = min(64, width - tileX)
                let th = min(64, height - tileY)
                try need(1)
                let sub = data[pos]
                pos += 1
                var pixels: [(UInt8, UInt8, UInt8)] = []
                pixels.reserveCapacity(tw * th)

                switch sub {
                case 0:  // Raw
                    for _ in 0..<(tw * th) { pixels.append(try cpixel()) }
                case 1:  // Solid
                    let p = try cpixel()
                    pixels = Array(repeating: p, count: tw * th)
                case 2...16:  // Packed palette
                    let size = Int(sub)
                    var palette: [(UInt8, UInt8, UInt8)] = []
                    for _ in 0..<size { palette.append(try cpixel()) }
                    let bits: Int = size == 2 ? 1 : (size <= 4 ? 2 : 4)
                    let rowBytes = (tw * bits + 7) / 8
                    try need(rowBytes * th)
                    for row in 0..<th {
                        var bitPos = row * rowBytes * 8
                        for _ in 0..<tw {
                            var value = 0
                            for _ in 0..<bits {
                                let byte = data[pos + bitPos / 8]
                                value = (value << 1) | Int((byte >> (7 - bitPos % 8)) & 1)
                                bitPos += 1
                            }
                            guard value < palette.count else {
                                throw ClientError.decode("ZRLE 调色板索引越界 \(value)/\(palette.count)")
                            }
                            pixels.append(palette[value])
                        }
                    }
                    pos += rowBytes * th
                case 128:  // Plain RLE
                    while pixels.count < tw * th {
                        let p = try cpixel()
                        let length = try runLength()
                        pixels.append(contentsOf: repeatElement(p, count: length))
                    }
                case 130...255:  // Palette RLE
                    let size = Int(sub) - 128
                    var palette: [(UInt8, UInt8, UInt8)] = []
                    for _ in 0..<size { palette.append(try cpixel()) }
                    while pixels.count < tw * th {
                        try need(1)
                        let indexByte = data[pos]
                        pos += 1
                        let length = (indexByte & 0x80) != 0 ? try runLength() : 1
                        let index = Int(indexByte & 0x7F)
                        guard index < palette.count else {
                            throw ClientError.decode("ZRLE RLE 调色板索引越界 \(index)/\(palette.count)")
                        }
                        pixels.append(contentsOf: repeatElement(palette[index], count: length))
                    }
                default:
                    throw ClientError.decode("未知 ZRLE 子编码 \(sub)")
                }

                guard pixels.count >= tw * th else {
                    throw ClientError.decode("ZRLE tile 像素不足 \(pixels.count)/\(tw * th)")
                }
                for row in 0..<th {
                    for col in 0..<tw {
                        write(pixels[row * tw + col], gx: x + tileX + col, gy: y + tileY + row)
                    }
                }
                tileX += 64
            }
            tileY += 64
        }
    }

    // MARK: - publishing

    private func publish(size: (Int, Int), rebuild: Bool) {
        let began = CFAbsoluteTimeGetCurrent()
        // Copy out of the mutable framebuffer. Handing a CGDataProvider a
        // buffer another thread keeps writing produces torn frames.
        let owned = Data(bytes: framebuffer, count: framebuffer.count)
        guard let provider = CGDataProvider(data: owned as CFData) else { return }
        guard let image = CGImage(
            width: size.0,
            height: size.1,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: size.0 * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
            ),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else { return }
        let nsImage = NSImage(cgImage: image, size: NSSize(width: size.0, height: size.1))
        let elapsed = (CFAbsoluteTimeGetCurrent() - began) * 1000

        frameCount += 1
        deliveredFrames += 1
        let now = CFAbsoluteTimeGetCurrent()
        let fps: Double
        if now > statsEpoch {
            fps = Double(frameCount) / (now - statsEpoch)
        } else {
            fps = 0
        }
        if now - statsEpoch > 1.0 {
            frameCount = 0
            statsEpoch = now
        }
        let received = bytesReceived
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onFrame?(nsImage)
            self.onStats?(elapsed, fps, received, 0)
        }
    }
}

/// Persistent zlib inflate state for ZRLE.
///
/// QEMU deflates each rectangle with Z_SYNC_FLUSH over one long-lived stream.
/// `zlib.decompress()` (or a fresh `z_stream` per rectangle) reports
/// "incomplete or truncated stream"; the decoder must be kept for the whole
/// connection and recreated only when the framebuffer is resized.
private final class ZRLEInflater {
    private var stream = z_stream()
    private var ready = false

    deinit {
        if ready { inflateEnd(&stream) }
    }

    func decode(_ input: [UInt8]) throws -> [UInt8] {
        if !ready {
            let status = inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
            guard status == Z_OK else { throw VNCClient.ClientError.decode("inflateInit=\(status)") }
            ready = true
        }
        guard !input.isEmpty else { return [] }

        var output: [UInt8] = []
        var scratch = [UInt8](repeating: 0, count: 1 << 18)

        try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Void in
            stream.next_in = UnsafeMutablePointer(
                mutating: raw.baseAddress!.assumingMemoryBound(to: Bytef.self)
            )
            stream.avail_in = uInt(raw.count)

            while true {
                var produced = 0
                var status: Int32 = Z_OK
                scratch.withUnsafeMutableBytes { dst in
                    stream.next_out = dst.baseAddress!.assumingMemoryBound(to: Bytef.self)
                    stream.avail_out = uInt(dst.count)
                    status = zlib.inflate(&stream, Z_SYNC_FLUSH)
                    produced = dst.count - Int(stream.avail_out)
                    if produced > 0 {
                        output.append(contentsOf: dst[0..<produced])
                    }
                }
                if status == Z_STREAM_END || status == Z_DATA_ERROR || status < 0 {
                    throw VNCClient.ClientError.decode("inflate=\(status)")
                }
                if stream.avail_in == 0 && produced < scratch.count { break }
                if produced == 0 && stream.avail_in == 0 { break }
            }
        }
        return output
    }
}
