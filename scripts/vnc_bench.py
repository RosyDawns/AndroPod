"""Measure VNC bandwidth while the guest screen is actually changing.

Why this exists
---------------
A static desktop tells you almost nothing: QEMU's VNC server sends damage
rectangles only, so an idle screen is ~2 KB/s for every encoding. The number
that matters for "does VNC beat screendump" is what happens when the frame is
changing every 16 ms (a scrolling UI, or a Unity game).

Two modes
---------
parse  Strictly parse Raw / CopyRect / ZRLE / DesktopSize rectangles. Gives
       frame rate and bytes per frame, but cannot handle Hextile or Tight,
       whose payload length is only discoverable by walking the sub-encodings.
drain  Never parses rectangles. A dedicated thread keeps the socket drained and
       counts bytes; a second thread issues incremental update requests; a third
       injects pointer drags. Works for every encoding, including Tight/JPEG.
       This is the mode used for the headline bandwidth numbers.

Input is injected over the same RFB connection (PointerEvent), so no adb or
second QMP channel is involved and the guest workload is identical across runs.
"""

from __future__ import annotations

import argparse
import socket
import struct
import threading
import time

ENC_RAW = 0
ENC_COPYRECT = 1
ENC_HEXTILE = 5
ENC_TIGHT = 7
ENC_ZRLE = 16
ENC_DESKTOPSIZE = -223
ENC_NAMES = {
    ENC_RAW: "Raw", ENC_COPYRECT: "CopyRect", ENC_HEXTILE: "Hextile",
    ENC_TIGHT: "Tight", ENC_ZRLE: "ZRLE", ENC_DESKTOPSIZE: "DesktopSize",
}


def recv_exact(sock: socket.socket, n: int) -> bytes:
    buf = bytearray()
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("closed")
        buf += chunk
    return bytes(buf)


def handshake(sock: socket.socket) -> tuple[int, int, bytes]:
    version = recv_exact(sock, 12)
    sock.sendall(b"RFB 003.008\n")
    count = recv_exact(sock, 1)[0]
    if count == 0:
        reason_len = struct.unpack(">I", recv_exact(sock, 4))[0]
        raise RuntimeError("rejected: " + recv_exact(sock, reason_len).decode(errors="replace"))
    recv_exact(sock, count)
    sock.sendall(bytes([1]))                      # SecurityType None
    if struct.unpack(">I", recv_exact(sock, 4))[0] != 0:
        raise RuntimeError("SecurityResult != OK")
    sock.sendall(bytes([1]))                      # shared
    head = recv_exact(sock, 24)
    width, height = struct.unpack(">HH", head[:4])
    name_len = struct.unpack(">I", head[20:24])[0]
    recv_exact(sock, name_len)
    return width, height, version


def set_pixel_format(sock: socket.socket) -> None:
    """32bpp, depth 24, little endian, BGRA byte order in memory.

    red-shift=16 / green=8 / blue=0 means a 32-bit pixel stored on a little
    endian host is [B, G, R, pad]. That is exactly CGImage's
    byteOrder32Little + alphaNoneSkipFirst layout, and ZRLE's CPIXEL (the low
    three bytes) is BGR too, so the Swift decoder needs no channel shuffle.
    """
    pf = struct.pack(
        ">BBBBHHHBBB3x",
        32, 24, 0, 1,          # bpp, depth, big-endian, truecolour
        255, 255, 255,         # red/green/blue max
        16, 8, 0,             # shifts
    )
    sock.sendall(struct.pack(">BB2x", 0, 0) + pf)   # type 0, padding + 16-byte pf


def set_encodings(sock: socket.socket, encodings: list[int]) -> None:
    msg = struct.pack(">BBH", 2, 0, len(encodings))
    msg += b"".join(struct.pack(">i", e) for e in encodings)
    sock.sendall(msg)


SEND_LOCK = threading.Lock()


def send(sock: socket.socket, payload: bytes) -> None:
    """Two threads (input + requester) write to one RFB socket. Serialise them
    so an input event can never be spliced into the middle of an update request.
    """
    with SEND_LOCK:
        sock.sendall(payload)


def update_request(sock: socket.socket, incremental: bool, w: int, h: int) -> None:
    send(sock, struct.pack(">BBHHHH", 3, 1 if incremental else 0, 0, 0, w, h))


def drag_once(sock: socket.socket, w: int, h: int, phase: int) -> None:
    """One horizontal swipe across the launcher, repeated to keep animation on."""
    y = h // 2
    start_x = int(w * 0.18)
    end_x = int(w * 0.82)
    direction = 1 if phase % 2 == 0 else -1
    x0, x1 = (start_x, end_x) if direction > 0 else (end_x, start_x)
    send(sock, struct.pack(">BBHH", 5, 1, x0, y))       # press
    steps = 12
    for i in range(1, steps + 1):
        x = x0 + (x1 - x0) * i // steps
        send(sock, struct.pack(">BBHH", 5, 1, x, y))
        time.sleep(0.012)
    send(sock, struct.pack(">BBHH", 5, 0, x1, y))       # release
    time.sleep(0.05)


def input_worker(sock: socket.socket, w: int, h: int, stop: threading.Event) -> None:
    phase = 0
    while not stop.is_set():
        try:
            drag_once(sock, w, h, phase)
        except OSError:
            return
        phase += 1


def parse_run(sock: socket.socket, w: int, h: int, seconds: float,
              stop: threading.Event) -> dict:
    """Strict rectangle parsing; returns as soon as an unsupported encoding appears."""
    bpp = 4
    update_request(sock, False, w, h)
    frames = 0
    rects = 0
    total = 0
    per_frame: list[int] = []
    unsupported: int | None = None
    started = time.monotonic()
    deadline = started + seconds

    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        # Wait only until the measurement window ends. Blocking recv with a
        # fixed 20 s timeout made an idle screen inflate the elapsed time by
        # exactly that timeout and destroyed the KB/s figure.
        import select
        if not select.select([sock], [], [], min(remaining, 0.25))[0]:
            if time.monotonic() >= deadline:
                break
            continue
        try:
            kind = recv_exact(sock, 1)[0]
        except (socket.timeout, ConnectionError):
            break
        if kind == 0:
            recv_exact(sock, 1)
            n_rects = struct.unpack(">H", recv_exact(sock, 2))[0]
            frame_bytes = 0
            for _ in range(n_rects):
                x, y, rw, rh = struct.unpack(">HHHH", recv_exact(sock, 8))
                enc = struct.unpack(">i", recv_exact(sock, 4))[0]
                frame_bytes += 12
                rects += 1
                if enc == ENC_RAW:
                    payload = rw * rh * bpp
                elif enc == ENC_ZRLE:
                    length = struct.unpack(">I", recv_exact(sock, 4))[0]
                    frame_bytes += 4
                    payload = length
                elif enc == ENC_COPYRECT:
                    payload = 4
                elif enc == ENC_DESKTOPSIZE:
                    payload = 0
                    w, h = rw, rh
                else:
                    unsupported = enc
                    break
                if payload:
                    recv_exact(sock, payload)
                    frame_bytes += payload
            if unsupported is not None:
                break
            frames += 1
            per_frame.append(frame_bytes)
            total += frame_bytes
            update_request(sock, True, w, h)
        elif kind == 1:
            recv_exact(sock, 3)
            n = struct.unpack(">H", recv_exact(sock, 2))[0]
            recv_exact(sock, n * 6)
        elif kind == 2:
            pass
        elif kind == 3:
            recv_exact(sock, 3)
            n = struct.unpack(">I", recv_exact(sock, 4))[0]
            recv_exact(sock, n)
        else:
            break

    elapsed = time.monotonic() - started
    return {
        "mode": "parse", "seconds": elapsed, "frames": frames, "rects": rects,
        "bytes": total, "per_frame": per_frame, "unsupported": unsupported,
    }


def drain_run(sock: socket.socket, w: int, h: int, seconds: float,
              stop: threading.Event) -> dict:
    """Count every byte QEMU pushes, without interpreting rectangle payloads."""
    sock.settimeout(0.01)
    total = 0
    lock = threading.Lock()

    def drain() -> None:
        nonlocal total
        while not stop.is_set():
            try:
                chunk = sock.recv(1 << 20)
            except socket.timeout:
                continue
            except OSError:
                return
            if not chunk:
                return
            with lock:
                total += len(chunk)

    def requester() -> None:
        # Ask for the next change at ~60 Hz. QEMU coalesces damage between
        # requests, so a faster client never sees stale frames.
        while not stop.is_set():
            try:
                update_request(sock, True, w, h)
            except OSError:
                return
            stop.wait(1.0 / 60)

    threading.Thread(target=drain, daemon=True).start()
    threading.Thread(target=requester, daemon=True).start()
    update_request(sock, False, w, h)
    started = time.monotonic()
    stop.wait(seconds)
    stop.set()
    elapsed = time.monotonic() - started
    return {"mode": "drain", "seconds": elapsed, "bytes": total,
            "frames": 0, "rects": 0, "per_frame": [], "unsupported": None}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=5901)
    ap.add_argument("--seconds", type=float, default=4.0)
    ap.add_argument("--mode", choices=["parse", "drain", "both"], default="both")
    ap.add_argument("--encodings", default="raw,zrle,hextile,tight")
    ap.add_argument("--no-input", action="store_true", help="measure idle screen")
    args = ap.parse_args()

    lookup = {"raw": ENC_RAW, "zrle": ENC_ZRLE, "hextile": ENC_HEXTILE,
              "tight": ENC_TIGHT}
    requested = [lookup[k.strip()] for k in args.encodings.split(",") if k.strip()]

    print(f"目标 {args.host}:{args.port}  时长 {args.seconds}s  输入={'关' if args.no_input else '开'}")

    for enc in requested:
        modes = ["parse", "drain"] if args.mode == "both" else [args.mode]
        for mode in modes:
            # parse cannot walk Hextile/Tight payloads
            if mode == "parse" and enc in (ENC_HEXTILE, ENC_TIGHT):
                continue
            sock = socket.create_connection((args.host, args.port), timeout=5)
            sock.settimeout(20)
            try:
                w, h, version = handshake(sock)
                set_pixel_format(sock)
                # Ask for exactly one encoding so QEMU cannot silently pick
                # another one; DesktopSize is a pseudo-encoding and harmless.
                set_encodings(sock, [enc, ENC_DESKTOPSIZE])
                stop = threading.Event()
                if not args.no_input:
                    threading.Thread(target=input_worker, args=(sock, w, h, stop),
                                     daemon=True).start()
                result = (parse_run(sock, w, h, args.seconds, stop) if mode == "parse"
                          else drain_run(sock, w, h, args.seconds, stop))
            finally:
                stop.set()
                sock.close()

            secs = result["seconds"]
            kb = result["bytes"] / 1024
            tag = f"{ENC_NAMES.get(enc, enc):>9} [{mode:>5}]"
            if secs <= 0:
                print(f"  {tag}  无数据")
                continue
            line = f"  {tag}  {kb/secs:8.0f} KB/s   共 {kb:8.0f} KB / {secs:.1f}s"
            if result["frames"]:
                pf = result["per_frame"]
                line += (f"   {result['frames']/secs:5.1f} fps"
                         f"   {sum(pf)/len(pf)/1024:6.0f} KB/帧"
                         f"   {result['rects']} 矩形")
            if result["unsupported"] is not None:
                line += f"  (解析中止: {ENC_NAMES.get(result['unsupported'])})"
            print(line)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
