#!/usr/bin/env python3
"""Minimal ADB protocol probe.

`adb`'s client abstraction hides where the handshake actually fails. This speaks
the wire protocol directly so we can see whether the device answers CNXN, asks
for AUTH, or refuses the stream.



    python3 scripts/adb_probe.py [host] [port]
"""

from __future__ import annotations

import socket
import struct
import sys

A_CNXN = 0x4E584E43
A_AUTH = 0x48545541
A_OPEN = 0x4E45504F
A_OKAY = 0x59414B4F
A_CLSE = 0x45534C43
A_WRTE = 0x45545257
A_STLS = 0x534C5453

NAMES = {
    A_CNXN: "CNXN",
    A_AUTH: "AUTH",
    A_OPEN: "OPEN",
    A_OKAY: "OKAY",
    A_CLSE: "CLSE",
    A_WRTE: "WRTE",
    A_STLS: "STLS",
}

A_VERSION = 0x01000001
MAXDATA = 256 * 1024


def describe(command: int, arg0: int, arg1: int, payload: bytes) -> str:
    name = NAMES.get(command, f"0x{command:08X}")
    if command == A_CNXN:
        payload = payload.split(b"\x00")[0]
        return f"{name} version=0x{arg0:08X} maxdata={arg1} banner={payload!r}"
    if command == A_AUTH:
        kind = {1: "TOKEN", 2: "SIGNATURE", 3: "RSAPUBLICKEY"}.get(arg0, str(arg0))
        return f"{name} type={kind} len={len(payload)}"
    if command in (A_OPEN, A_WRTE):
        return f"{name} local={arg0} remote={arg1} len={len(payload)} payload={payload[:60]!r}"
    return f"{name} arg0={arg0} arg1={arg1} len={len(payload)}"


def recv_exact(sock: socket.socket, count: int) -> bytes:
    buffer = b""
    while len(buffer) < count:
        chunk = sock.recv(count - len(buffer))
        if not chunk:
            raise ConnectionError("连接关闭")
        buffer += chunk
    return buffer


def read_packet(sock: socket.socket) -> tuple[int, int, int, bytes]:
    header = recv_exact(sock, 24)
    command, arg0, arg1, length, _checksum, magic = struct.unpack("<6I", header)
    if magic != (command ^ 0xFFFFFFFF):
        raise ValueError(f"magic 不匹配: {magic:08X}")
    payload = recv_exact(sock, length) if length else b""
    return command, arg0, arg1, payload


def send_packet(sock: socket.socket, command: int, arg0: int, arg1: int, payload: bytes = b"") -> None:
    header = struct.pack(
        "<6I", command, arg0, arg1, len(payload), 0, command ^ 0xFFFFFFFF
    )
    sock.sendall(header + payload)


def probe_service(host: str, port: int, service: str) -> str:
    """Open one service on a fresh connection and report what came back."""
    try:
        sock = socket.create_connection((host, port), timeout=5)
    except OSError as exc:
        return f"连接失败: {exc}"
    sock.settimeout(3)

    try:
        send_packet(sock, A_CNXN, A_VERSION, MAXDATA, b"host::features=shell_v2,cmd")
        # Read until the device's CNXN.
        for _ in range(3):
            command, arg0, arg1, payload = read_packet(sock)
            if command == A_CNXN:
                break
        else:
            return "没有收到设备 CNXN"

        send_packet(sock, A_OPEN, 1, 0, service.encode() + b"\x00")
        replies = []
        for _ in range(4):
            try:
                command, _arg0, _arg1, payload = read_packet(sock)
            except socket.timeout:
                break
            replies.append(NAMES.get(command, hex(command)))
            if command == A_WRTE:
                replies[-1] = f"WRTE({payload[:40]!r})"
            if command == A_CLSE:
                break
        return " → ".join(replies) if replies else "无响应"
    except Exception as exc:  # noqa: BLE001
        return f"异常: {exc}"
    finally:
        sock.close()


def probe_all(host: str, port: int) -> int:
    services = [
        "host:version",              # 不需要 fork 进程的宿主服务
        "host:devices",
        "shell:echo hi",             # 需要 fork /system/bin/sh
        "shell,v2,raw:echo hi",      # shell_v2 变体
        "log:main",                  # 需要 fork logcat
        "reboot:",                   # 需要权限，不需要命令
        "sync:",                     # 文件同步
    ]
    print(f"逐项探测 {host}:{port}")
    for service in services:
        result = probe_service(host, port, service)
        print(f"  {service:<24} {result}")
    return 0


def main() -> int:
    host = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 5555

    if "--all" in sys.argv:
        return probe_all(host, port)

    sock = socket.create_connection((host, port), timeout=5)
    sock.settimeout(5)
    print(f"已连接 {host}:{port}")

    # Phase 1: whatever the device says first.
    try:
        command, arg0, arg1, payload = read_packet(sock)
        print("设备主动发送:", describe(command, arg0, arg1, payload))
    except Exception as exc:  # noqa: BLE001
        print("设备没有主动发送:", exc)

    # Phase 2: host CNXN.
    banner = b"host::features=shell_v2,cmd,stat_v2,ls_v2,fixed_push_mkdir,apex,abb,abb_exec,remount_shell,track_app,sendrecv_v2,libusb,push_sync"
    send_packet(sock, A_CNXN, A_VERSION, MAXDATA, banner)
    print("已发送 host CNXN")

    for _ in range(4):
        try:
            command, arg0, arg1, payload = read_packet(sock)
        except socket.timeout:
            print("  (超时，无更多数据)")
            break
        except Exception as exc:  # noqa: BLE001
            print("  读取失败:", exc)
            break
        print("  ←", describe(command, arg0, arg1, payload))
        if command == A_CNXN:
            break

    # Phase 3: try to open a shell stream.
    print("发送 OPEN shell:echo hi")
    try:
        send_packet(sock, A_OPEN, 1, 0, b"shell:echo hi\x00")
    except Exception as exc:  # noqa: BLE001
        print("  发送失败:", exc)
        return 1

    for _ in range(6):
        try:
            command, arg0, arg1, payload = read_packet(sock)
        except socket.timeout:
            print("  (超时，无更多数据)")
            break
        except Exception as exc:  # noqa: BLE001
            print("  读取失败:", exc)
            break
        print("  ←", describe(command, arg0, arg1, payload))

    sock.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
