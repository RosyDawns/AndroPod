"""Grab one full frame from a VNC server and write it as PPM.

Uses Raw encoding only, so the payload is trivially predictable:
  width * height * bytesPerPixel, BGRA order, little endian.

Its job is diagnosis: prove whether the VNC framebuffer matches what the guest
is actually showing, without needing a full VNC client.
"""

from __future__ import annotations

import socket
import struct
import sys


def recv_exact(sock: socket.socket, n: int) -> bytes:
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("closed")
        buf += chunk
    return buf


def main() -> int:
    host = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 11801
    out_path = sys.argv[3] if len(sys.argv) > 3 else "/tmp/vnc_frame.ppm"

    sock = socket.create_connection((host, port), timeout=15)
    sock.settimeout(15)

    recv_exact(sock, 12)
    sock.sendall(b"RFB 003.008\n")
    n = recv_exact(sock, 1)[0]
    recv_exact(sock, n)
    sock.sendall(bytes([1]))
    recv_exact(sock, 4)

    sock.sendall(bytes([1]))
    head = recv_exact(sock, 24)
    width, height = struct.unpack(">HH", head[:4])
    bits = head[4]
    bpp = bits // 8
    name_len = struct.unpack(">I", head[20:24])[0]
    name = recv_exact(sock, name_len).decode(errors="replace") if name_len else ""

    # Raw only
    sock.sendall(struct.pack(">BBH", 2, 0, 1) + struct.pack(">i", 0))
    sock.sendall(struct.pack(">BBHHHH", 3, 0, 0, 0, width, height))

    while True:
        kind = recv_exact(sock, 1)[0]
        if kind == 0:
            recv_exact(sock, 1)
            n_rects = struct.unpack(">H", recv_exact(sock, 2))[0]
            canvas = bytearray(width * height * 3)
            for _ in range(n_rects):
                x, y, w, h = struct.unpack(">HHHH", recv_exact(sock, 8))
                enc = struct.unpack(">i", recv_exact(sock, 4))[0]
                if enc != 0:
                    print(f"意外编码 {enc}")
                    return 1
                for row in range(h):
                    line = recv_exact(sock, w * bpp)
                    # BGRX -> RGB
                    base = ((y + row) * width + x) * 3
                    for col in range(w):
                        p = col * bpp
                        o = base + col * 3
                        canvas[o] = line[p + 2]
                        canvas[o + 1] = line[p + 1]
                        canvas[o + 2] = line[p]
            with open(out_path, "wb") as handle:
                handle.write(f"P6\n{width} {height}\n255\n".encode())
                handle.write(bytes(canvas))
            print(f"已保存 {out_path}  {width}x{height}  ({name})")
            sock.close()
            return 0
        if kind == 1:
            recv_exact(sock, 3)
            m = struct.unpack(">H", recv_exact(sock, 2))[0]
            recv_exact(sock, m * 6)
        elif kind == 2:
            pass
        elif kind == 3:
            recv_exact(sock, 3)
            m = struct.unpack(">I", recv_exact(sock, 4))[0]
            recv_exact(sock, m)


if __name__ == "__main__":
    raise SystemExit(main())
