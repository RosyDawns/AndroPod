import Accelerate
import CoreGraphics
import Foundation

/// Decodes QEMU's screendump output into a `CGImage`.
///
/// Why not `NSImage(data:)`: asking ImageIO to sniff and decode a format costs
/// far more than the data is worth here. Measured on this machine, a 1280x800
/// frame costs 129 ms as PNG versus 6 ms as raw PPM — PNG compression runs on
/// QEMU's main loop, so it stalls the whole guest, not just the viewer.
///
/// QEMU writes a binary P6 PPM: `P6\n<width> <height>\n255\n` followed by
/// width*height*3 bytes of RGB. We parse the header by hand and convert to
/// BGRA with vImage so CoreGraphics gets a format it can blit directly.
public enum PPMDecoder {
    struct Header {
        let width: Int
        let height: Int
        let offset: Int
    }

    public static func decode(_ data: Data) -> CGImage? {
        let count = data.count
        guard count > 15 else { return nil }

        return data.withUnsafeBytes { raw -> CGImage? in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            guard let header = parseHeader(base, count: count) else { return nil }
            let pixels = header.width * header.height
            guard pixels > 0, count >= header.offset + pixels * 3 else { return nil }

            let rowBytes = header.width * 4
            let byteCount = rowBytes * header.height
            let dst = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 64)
            defer { dst.deallocate() }

            var srcBuffer = vImage_Buffer(
                data: UnsafeMutableRawPointer(mutating: base + header.offset),
                height: vImagePixelCount(header.height),
                width: vImagePixelCount(header.width),
                rowBytes: header.width * 3
            )
            var dstBuffer = vImage_Buffer(
                data: dst,
                height: vImagePixelCount(header.height),
                width: vImagePixelCount(header.width),
                rowBytes: rowBytes
            )
            // Target BGRA. This entry point takes no permute map: it fixes the
            // channel order (B,G,R,A) and only asks what to put in the alpha
            // byte. PPM carries no alpha, so fill it with 255.
            // Signature: (src, aSrc, Pixel_8 alpha, dest, bool premultiply, flags)
            let error = vImageConvert_RGB888toBGRA8888(
                &srcBuffer, nil, 255, &dstBuffer, false,
                vImage_Flags(kvImageNoFlags)
            )
            guard error == kvImageNoError else { return nil }

            // Copy out of the scratch buffer instead of handing it to Data.
            // Wrapping the allocation in `Data(bytesNoCopy:deallocator:)` while
            // also owning it here meant two owners calling deallocate on the
            // same pointer — a double free that crashes with SIGTRAP the moment
            // a frame is decoded. One extra 4 MB copy costs about a millisecond.
            let owned = Data(bytes: dst, count: byteCount)
            guard let provider = CGDataProvider(data: owned as CFData) else { return nil }
            return CGImage(
                width: header.width,
                height: header.height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: rowBytes,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                        | CGBitmapInfo.byteOrder32Little.rawValue
                ),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        }
    }

    /// Parses `P6\n<w> <h>\n<maxval>\n`. Tokens may be separated by any run of
    /// whitespace and may carry `#` comments, per the PPM spec.
    static func parseHeader(_ p: UnsafePointer<UInt8>, count: Int) -> Header? {
        guard p[0] == 0x50, p[1] == 0x36 else { return nil }  // "P6"
        var i = 2
        var values: [Int] = []

        while values.count < 3 {
            guard i < count else { return nil }
            let c = p[i]
            if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D {
                i += 1
                continue
            }
            if c == 0x23 {  // '#'
                while i < count && p[i] != 0x0A { i += 1 }
                continue
            }
            var value = 0
            var digits = 0
            while i < count {
                let d = p[i]
                guard d >= 0x30, d <= 0x39 else { break }
                value = value * 10 + Int(d - 0x30)
                i += 1
                digits += 1
            }
            guard digits > 0 else { return nil }
            values.append(value)
        }

        guard values[2] == 255 else { return nil }
        // Exactly one whitespace byte terminates the header.
        guard i < count else { return nil }
        return Header(width: values[0], height: values[1], offset: i + 1)
    }
}
