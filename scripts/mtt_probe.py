#!/usr/bin/env python3
"""Probe how QMP `mtt` events translate into kernel input events.

QEMU's error messages pin down the payload shape (all five fields are required
and flat under `data`):

    {"type": "mtt", "data": {"type": "<phase>", "slot": 0,
                             "tracking-id": 0, "axis": "x"|"y", "value": 0..32767}}

What is *not* documented is the phase semantics: which combination actually
makes the virtio-multitouch device emit ABS_MT_POSITION_X/Y. This script sends a
candidate sequence while capturing `getevent` on the guest, so the result is
measured rather than guessed.

    python3 scripts/mtt_probe.py <sequence-name>
"""

from __future__ import annotations

import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "engine"))

from andropod import paths  # noqa: E402
from andropod.config import VMConfig  # noqa: E402
from andropod.vm import VM  # noqa: E402

TOUCH_DEVICE = "/dev/input/event1"
ADB_SERVER_PORT = "5111"

# Each sequence is a list of (phase, slot, tracking-id, axis, value).
SEQUENCES: dict[str, list[tuple[str, int, int, str, int]]] = {
    # What we tried first: one axis per phase.
    "per-phase": [
        ("begin", 0, 0, "x", 16383),
        ("update", 0, 0, "y", 20479),
        ("end", 0, 0, "x", 16383),
    ],
    # Position first, then declare the finger.
    "position-then-down": [
        ("update", 0, 0, "x", 16383),
        ("update", 0, 0, "y", 20479),
        ("begin", 0, 0, "x", 16383),
        ("end", 0, 0, "x", 16383),
    ],
    # Both axes inside begin, then lift with a real tracking id.
    "both-axes-begin": [
        ("begin", 0, 1, "x", 16383),
        ("begin", 0, 1, "y", 20479),
        ("update", 0, 1, "x", 16383),
        ("update", 0, 1, "y", 20479),
        ("end", 0, 1, "x", 16383),
    ],
    # Explicit cancel to see whether it differs from end.
    "cancel": [
        ("begin", 0, 2, "x", 16383),
        ("update", 0, 2, "y", 20479),
        ("cancel", 0, 2, "x", 16383),
    ],
}


def mtt(vm: VM, phase: str, slot: int, tracking: int, axis: str, value: int) -> None:
    vm.qmp.execute(
        "input-send-event",
        {
            "events": [
                {
                    "type": "mtt",
                    "data": {
                        "type": phase,
                        "slot": slot,
                        "tracking-id": tracking,
                        "axis": axis,
                        "value": value,
                    },
                }
            ]
        },
    )


def main() -> int:
    name = sys.argv[1] if len(sys.argv) > 1 else "both-axes-begin"
    sequence = SEQUENCES.get(name)
    if sequence is None:
        print(f"未知序列 {name!r}，可选: {', '.join(SEQUENCES)}")
        return 2

    cfg = VMConfig.load(paths.instance_dir("lineage") / "instance.json")
    vm = VM(cfg, paths.instance_dir("lineage"))
    vm.attach()

    environment = dict(os.environ)
    environment["ANDROID_ADB_SERVER_PORT"] = ADB_SERVER_PORT
    watcher = subprocess.Popen(
        ["adb", "-s", "127.0.0.1:5555", "shell", f"getevent -c 24 -l {TOUCH_DEVICE}"],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        env=environment,
    )
    time.sleep(1.5)

    print(f"序列: {name}")
    for phase, slot, tracking, axis, value in sequence:
        print(f"  -> {phase:7s} slot={slot} id={tracking} {axis}={value}")
        mtt(vm, phase, slot, tracking, axis, value)
        time.sleep(0.08)

    time.sleep(1.5)
    watcher.terminate()
    try:
        output = watcher.communicate(timeout=5)[0]
    except subprocess.TimeoutExpired:
        watcher.kill()
        output = watcher.communicate()[0]

    print("\n--- 内核收到的事件 ---")
    lines = [line for line in (output or "").splitlines() if line.strip()]
    if not lines:
        print("(无)")
    for line in lines:
        print(" ", line)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
