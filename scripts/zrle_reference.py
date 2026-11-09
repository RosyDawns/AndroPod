"""Reference ZRLE decoder + protocol probe.

Purpose: before writing the Swift client, pin down the two things that silently
corrupt the picture if guessed wrong:

  1. QEMU keeps ONE zlib stream for the whole RFB connection. Each ZRLE
     rectangle is a `Z_SYNC_FLUSH`ed chunk, so standalone `zlib.decompress`
     fails with "incomplete or truncated stream". A persistent decompressobj
     is mandatory.
  2. CPIXEL layout. With bpp=32/depth=24/true-colour/max=255 the RFB spec
     allows a 3-byte CPIXEL (padding byte dropped). We verify against a QMP
     screendump of the very same frame.

Run with the guest idle so the full-screen update is deterministic.
"""

from __future__ import annotations

import json
import socket
import struct
import sys
import zlib
from pathlib import Path

HOST, PORT = "127.0.0.1", 5901
QMP = "/tmp/vt/qmp.sock"


def rx(sock: socket.socket, n: int) -> bytes:
    buf = bytearray()
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("closed")
        buf += chunk
    return bytes(buf)


def qmp(cmd: dict) -> dict:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(QMP)
    f = s.makefile("rb")
    f.readline()
    s.sendall((json.dumps({"execute": "qmp_capabilities"}) + "\n").encode())
    f.readline()
    s.sendall((json.dumps(cmd) + "\n").encode())
    while True:
        reply = json.loads(f.readline())
        if "event" in reply:
            continue
        s.close()
        return reply


def screendump(path: str) -> bytes:
    qmp({"execute": "screendump", "arguments": {"filename": path}})
    data = Path(path).read_bytes()
    # P6 header: b"P6\n<w> <h>\n255\n"
    idx = 0
    for _ in range(3):
        idx = data.index(b"\n", idx) + 1
    return data[idx:]


def connect() -> tuple[socket.socket, int, int]:
    s = socket.create_connection((HOST, PORT), timeout=5)
    s.settimeout(10)
    rx(s, 12)
    s.sendall(b"RFB 003.008\n")
    count = rx(s, 1)[0]
    rx(s, count)
    s.sendall(bytes([1]))                       # SecurityType None
    rx(s, 4)                                   # SecurityResult
    s.sendall(bytes([1]))                       # shared
    head = rx(s, 24)
    w, h = struct.unpack(">HH", head[:4])
    print("server pixel format:", list(head[4:20]))
    nl = struct.unpack(">I", head[20:24])[0]
    rx(s, nl)
    return s, w, h


def set_pixel_format(s: socket.socket, depth: int) -> None:
    # 32bpp, little endian, true colour, BGRA byte order.
    # red-shift=16/green=8/blue=0 => memory bytes are [B,G,R,X].
    pf = struct.pack(">BBBBHHHBBB3x", 32, depth, 0, 1,
                     255, 255, 255, 16, 8, 0)
    s.sendall(struct.pack(">BB2x", 0, 0) + pf)


def zrle_tiles(data: bytes, w: int, h: int, cpixel: int,
               fb: bytearray, screen_w: int, rect_x: int, rect_y: int) -> int:
    """Decode one decompressed ZRLE rectangle. Returns bytes consumed."""
    pos = 0
    n = len(data)

    def pixel() -> bytes:
        nonlocal pos
        p = data[pos:pos + cpixel]
        pos += cpixel
        return p

    def runlen() -> int:
        nonlocal pos
        total = 1
        while True:
            b = data[pos]
            pos += 1
            total += b
            if b != 255:
                break
        return total

    ty = 0
    while ty < h:
        tx = 0
        while tx < w:
            tw, th = min(64, w - tx), min(64, h - ty)
            sub = data[pos]
            pos += 1
            pixels: list[bytes] = []
            if sub == 0:                                   # Raw
                pixels = [pixel() for _ in range(tw * th)]
            elif sub == 1:                                 # Solid
                p = pixel()
                pixels = [p] * (tw * th)
            elif 2 <= sub <= 16:                           # Packed palette
                palette = [pixel() for _ in range(sub)]
                bits = {2: 1, 3: 2, 4: 2}.get(sub, 4)
                if 5 <= sub <= 16:
                    bits = 4
                bits_per_row = (tw * bits + 7) // 8
                packed = data[pos:pos + bits_per_row * th]
                pos += bits_per_row * th
                for row in range(th):
                    bitpos = row * bits_per_row * 8
                    for col in range(tw):
                        val = 0
                        for _ in range(bits):
                            byte = packed[(bitpos // 8)]
                            val = (val << 1) | ((byte >> (7 - bitpos % 8)) & 1)
                            bitpos += 1
                        pixels.append(palette[val])
            elif sub == 128:                               # Plain RLE
                while len(pixels) < tw * th:
                    p = pixel()
                    pixels.extend([p] * runlen())
            elif 130 <= sub <= 255:                        # Palette RLE
                palette = [pixel() for _ in range(sub - 128)]
                while len(pixels) < tw * th:
                    idx = data[pos]
                    pos += 1
                    length = runlen() if idx & 0x80 else 1
                    pixels.extend([palette[idx & 0x7F]] * length)
            else:
                raise ValueError(f"unknown ZRLE subencoding {sub}")

            for row in range(th):
                for col in range(tw):
                    p = pixels[row * tw + col]
                    gx, gy = rect_x + tx + col, rect_y + ty + row
                    off = (gy * screen_w + gx) * 4
                    # QEMU's 3-byte CPIXEL drops the *padding* byte, not an
                    # RGB-to-BGR conversion: with blue-shift=0 the surviving
                    # bytes are already B,G,R. Copy them straight into BGRA.
                    # Treating them as R,G,B swaps red and blue — verified by
                    # a pixel match of only 4/704 against the screendump.
                    if cpixel == 3:
                        fb[off] = p[0]
                        fb[off + 1] = p[1]
                        fb[off + 2] = p[2]
                        fb[off + 3] = 255
                    else:
                        fb[off:off + 4] = p[:4]
            tx += 64
        ty += 64
    return pos


def main() -> int:
    depth = int(sys.argv[1]) if len(sys.argv) > 1 else 24
    cpixel = int(sys.argv[2]) if len(sys.argv) > 2 else 3

    s, w, h = connect()
    set_pixel_format(s, depth)
    s.sendall(struct.pack(">BBH", 2, 0, 2) + struct.pack(">i", 16)
              + struct.pack(">i", -223))
    s.sendall(struct.pack(">BBHHHH", 3, 0, 0, 0, w, h))

    # Ground truth from QMP.
    ppm_path = "/tmp/vt/zrle_truth.ppm"
    truth = screendump(ppm_path)
    print(f"ground truth: {len(truth)} bytes RGB for {w}x{h}")

    stream = zlib.decompressobj()
    fb = bytearray(w * h * 4)
    kind = rx(s, 1)[0]
    while kind != 0:
        if kind == 1:
            rx(s, 3)
            m = struct.unpack(">H", rx(s, 2))[0]
            rx(s, m * 6)
        elif kind == 3:
            rx(s, 3)
            m = struct.unpack(">I", rx(s, 4))[0]
            rx(s, m)
        kind = rx(s, 1)[0]
    rx(s, 1)
    n_rects = struct.unpack(">H", rx(s, 2))[0]
    print(f"framebuffer update: {n_rects} rects")

    total_decompressed = 0
    for i in range(n_rects):
        x, y, rw, rh = struct.unpack(">HHHH", rx(s, 8))
        enc = struct.unpack(">i", rx(s, 4))[0]
        if enc == 16:
            length = struct.unpack(">I", rx(s, 4))[0]
            comp = rx(s, length)
            raw = stream.decompress(comp)
            total_decompressed += len(raw)
            if i == 0:
                print(f"  rect0 {rw}x{rh} compressed={length} expanded={len(raw)} "
                      f"first subencoding={raw[0] if raw else '?'}")
                print(f"  expanded/{rw}x{rh} = {len(raw)/(rw*rh):.2f} bytes/pixel")
            try:
                used = zrle_tiles(raw, rw, rh, cpixel, fb, w, x, y)
                print(f"  rect{i} decoded {used}/{len(raw)} bytes")
            except Exception as exc:
                print(f"  rect{i} DECODE FAILED: {type(exc).__name__}: {exc}")
                return 2
        elif enc == 0:
            rx(s, rw * rh * 4)
        elif enc == 1:
            rx(s, 4)
        elif enc == -223:
            pass
        else:
            print(f"  unexpected encoding {enc}")
            return 2

    print(f"total decompressed: {total_decompressed} bytes")

    # Compare decoded BGRA against the PPM ground truth (RGB).
    matched = 0
    first_bad = None
    samples = 0
    for gy in range(0, h, 37):
        for gx in range(0, w, 41):
            o = (gy * w + gx) * 4
            t = (gy * w + gx) * 3
            samples += 1
            if (fb[o] == truth[t + 2] and fb[o + 1] == truth[t + 1]
                    and fb[o + 2] == truth[t]):
                matched += 1
            elif first_bad is None:
                first_bad = (gx, gy, tuple(fb[o:o + 4]), tuple(truth[t:t + 3]))
    print(f"pixel match: {matched}/{samples}")
    if first_bad:
        print("  first mismatch (x,y,BGRA,RGB):", first_bad)

    # Write a BGRA-ish PPM for visual confirmation.
    out = bytearray(f"P6\n{w} {h}\n255\n".encode())
    for o in range(0, len(fb), 4):
        out += bytes((fb[o + 2], fb[o + 1], fb[o]))
    Path("/tmp/vt/zrle_decoded.ppm").write_bytes(out)
    print("wrote /tmp/vt/zrle_decoded.ppm")
    s.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
