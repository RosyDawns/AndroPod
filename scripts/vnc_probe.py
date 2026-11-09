"""Minimal RFB (VNC) probe.

Measures what QEMU's VNC server actually sends: which encoding it picks, how
many bytes per frame, and how fast updates arrive. The point is to decide
whether VNC beats the current screendump path (3 MB per frame, ~7 ms, always
full-screen) before writing a real client in Swift.
"""

from __future__ import annotations

import socket
import struct
import sys
import time

ENC_NAMES = {0: "Raw", 1: "CopyRect", 2: "RRE", 5: "Hextile", 7: "Tight", 16: "ZRLE", -223: "DesktopSize"}


def recv_exact(sock: socket.socket, n: int) -> bytes:
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("connection closed")
        buf += chunk
    return buf


def handshake(sock: socket.socket) -> tuple[int, int, int]:
    version = recv_exact(sock, 12)
    print(f"  服务器版本: {version.decode(errors='replace').strip()}")
    sock.sendall(b"RFB 003.008\n")

    count = recv_exact(sock, 1)[0]
    if count == 0:
        reason_len = struct.unpack(">I", recv_exact(sock, 4))[0]
        print("  拒绝:", recv_exact(sock, reason_len).decode(errors="replace"))
        raise SystemExit(1)
    types = recv_exact(sock, count)
    print(f"  安全类型: {list(types)}")
    sock.sendall(bytes([1]))  # None
    result = struct.unpack(">I", recv_exact(sock, 4))[0]
    print(f"  认证结果: {result}")

    sock.sendall(bytes([1]))  # shared
    head = recv_exact(sock, 24)
    width, height = struct.unpack(">HH", head[:4])
    bits = head[4]
    depth = head[5]
    big_endian = head[6]
    true_colour = head[7]
    red_max, green_max, blue_max = struct.unpack(">HHH", head[8:14])
    name_len = struct.unpack(">I", head[20:24])[0]
    name = recv_exact(sock, name_len).decode(errors="replace") if name_len else ""
    print(f"  画面 {width}x{height}, {bits}bpp depth={depth}, truecolor={true_colour}, "
          f"be={big_endian}, max=({red_max},{green_max},{blue_max})")
    print(f"  名称: {name}")
    return width, height, bits


def main() -> int:
    host = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 5901
    seconds = float(sys.argv[3]) if len(sys.argv) > 3 else 4.0

    sock = socket.create_connection((host, port), timeout=5)
    sock.settimeout(20)
    width, height, bits = handshake(sock)

    only = sys.argv[4] if len(sys.argv) > 4 else "zrle"
    encodings = {"raw": [0], "zrle": [16], "hextile": [5]}.get(only, [16])
    msg = struct.pack(">BBH", 2, 0, len(encodings))
    msg += b"".join(struct.pack(">i", e) for e in encodings)
    sock.sendall(msg)
    print(f"  请求编码: {[ENC_NAMES.get(e, e) for e in encodings]}")

    def request(incremental: bool) -> None:
        sock.sendall(struct.pack(">BBHHHH", 3, 1 if incremental else 0, 0, 0, width, height))

    request(False)

    frames = 0
    total_bytes = 0
    encodings_seen: dict[int, int] = {}
    bytes_per_frame: list[int] = []
    bpp = bits // 8

    started = time.monotonic()
    deadline = started + seconds
    pending = 0  # rectangle payload bytes still to read

    while time.monotonic() < deadline:
        kind = recv_exact(sock, 1)[0]
        if kind == 0:  # FramebufferUpdate
            recv_exact(sock, 1)
            n_rects = struct.unpack(">H", recv_exact(sock, 2))[0]
            frame_start = total_bytes
            for _ in range(n_rects):
                x, y, w, h = struct.unpack(">HHHH", recv_exact(sock, 8))
                enc = struct.unpack(">i", recv_exact(sock, 4))[0]
                total_bytes += 12
                encodings_seen[enc] = encodings_seen.get(enc, 0) + 1

                if enc == 0:  # Raw
                    payload = w * h * bpp
                elif enc == 16:  # ZRLE: 4-byte length then data
                    length = struct.unpack(">I", recv_exact(sock, 4))[0]
                    total_bytes += 4
                    payload = length
                elif enc == 7 and False:  # Tight: 解析复杂，单独验证
                    control = recv_exact(sock, 1)
                    total_bytes += 1
                    ctype = control[0] >> 4
                    if ctype == 0x8 or ctype == 0x9:  # fill
                        payload = 0 if ctype == 0x8 else 0
                        if ctype == 0x8:
                            payload = 3 * (1 if bpp == 1 else 3)
                    elif ctype == 0x9:
                        payload = 3 * (1 if bpp == 1 else 3)
                    else:
                        compact = (control[0] & 0x0F) | (control[0] & 0x80)
                        length = 0
                        for _ in range(3):
                            b = recv_exact(sock, 1)[0]
                            total_bytes += 1
                            length |= (b & 0x7F) << (7 * _)
                            if not (b & 0x80):
                                break
                        payload = length
                    if payload:
                        recv_exact(sock, payload)
                        total_bytes += payload
                    continue
                else:  # unsupported here — drain conservatively and bail out
                    print(f"  未支持的编码 {enc} ({ENC_NAMES.get(enc, '?')}), w={w} h={h}")
                    sock.close()
                    return 2

                if payload:
                    recv_exact(sock, payload)
                    total_bytes += payload
            frames += 1
            bytes_per_frame.append(total_bytes - frame_start)
            request(True)
        elif kind == 1:  # SetColourMapEntries
            recv_exact(sock, 3)
            n = struct.unpack(">H", recv_exact(sock, 2))[0]
            recv_exact(sock, n * 6)
        elif kind == 2:  # Bell
            pass
        elif kind == 3:  # ServerCutText
            recv_exact(sock, 3)
            n = struct.unpack(">I", recv_exact(sock, 4))[0]
            recv_exact(sock, n)
        else:
            print(f"  未知消息类型 {kind}")
            break

    elapsed = time.monotonic() - started
    sock.close()

    print()
    print(f"  观察 {elapsed:.1f}s，收到 {frames} 帧，共 {total_bytes/1024:.0f} KB")
    print(f"  → 帧率 {frames/elapsed:.1f} fps，带宽 {total_bytes/1024/elapsed:.0f} KB/s")
    if bytes_per_frame:
        avg = sum(bytes_per_frame) / len(bytes_per_frame)
        print(f"  → 每帧平均 {avg/1024:.0f} KB（最小 {min(bytes_per_frame)/1024:.0f}，最大 {max(bytes_per_frame)/1024:.0f}）")
    print("  编码分布:", {ENC_NAMES.get(k, k): v for k, v in encodings_seen.items()})
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
