"""Input injection.

Two independent paths, and they are not equivalent:

1. **adb `input`** — goes through Android's InputManager. Reaches every surface:
   WebViews, Unity, system dialogs. Requires a working adb connection.
2. **QMP** — works with no adb at all, but only reaches surfaces that accept
   emulated pointer events.

Measured behaviour on LineageOS 23.2: QMP pointer events reach ordinary UI but
miss several surfaces; adb `input` reaches everything. Some buttons also stay
functionally disabled until their content has been scrolled — that looks exactly
like "input is broken" but is not.

Prefer path 1 and keep path 2 as the fallback for the window before adb is up.
"""

from __future__ import annotations

import os
import shutil
import subprocess

DEFAULT_ADB_SERVER_PORT = "5111"


def adb_binary() -> str | None:
    return shutil.which("adb")


def _run(args: list[str], server_port: str, timeout: float = 3) -> tuple[int, str]:
    binary = adb_binary()
    if not binary:
        return 127, "找不到 adb"
    environment = dict(os.environ)
    environment["ANDROID_ADB_SERVER_PORT"] = server_port
    try:
        result = subprocess.run(
            [binary, *args], capture_output=True, text=True, timeout=timeout, env=environment
        )
    except subprocess.TimeoutExpired:
        return 124, "超时"
    return result.returncode, (result.stdout or "") + (result.stderr or "")


def adb_ready(serial: str, server_port: str = DEFAULT_ADB_SERVER_PORT) -> bool:
    # Keep this short. A snapshot restore rewinds the guest but not the host TCP
    # proxy, so adbd is left holding a dead socket and every command hangs until
    # it times out. A 30 s default here once made a single tap take 30 s.
    code, output = _run(["-s", serial, "get-state"], server_port, 2)
    return code == 0 and "device" in output


def adb_tap(
    serial: str, x: int, y: int, server_port: str = DEFAULT_ADB_SERVER_PORT
) -> tuple[bool, str]:
    code, output = _run(["-s", serial, "shell", "input", "tap", str(x), str(y)], server_port)
    return code == 0 and "Exception" not in output, output.strip()


def adb_swipe(
    serial: str,
    x1: int,
    y1: int,
    x2: int,
    y2: int,
    duration_ms: int = 300,
    server_port: str = DEFAULT_ADB_SERVER_PORT,
) -> tuple[bool, str]:
    code, output = _run(
        [
            "-s", serial, "shell", "input", "swipe",
            str(x1), str(y1), str(x2), str(y2), str(duration_ms),
        ],
        server_port,
    )
    return code == 0 and "Exception" not in output, output.strip()


def adb_key(
    serial: str, key: str, server_port: str = DEFAULT_ADB_SERVER_PORT
) -> tuple[bool, str]:
    code, output = _run(["-s", serial, "shell", "input", "keyevent", key], server_port)
    return code == 0 and "Exception" not in output, output.strip()
