"""Instance configuration.

Kept deliberately small. Every field here maps to a real QEMU knob we have
verified, not to a feature we hope to build later.
"""

from __future__ import annotations

import json
from dataclasses import asdict, dataclass, field
from pathlib import Path


@dataclass
class VMConfig:
    name: str = "default"
    cpus: int = 4
    memory_mb: int = 2048

    machine: str = "virt"
    cpu: str = "host"
    accel: str = "hvf"

    # Boot media. `kernel` means direct kernel boot (no firmware, no bootloader);
    # this is how both the Alpine test guest and, later, Android images start.
    kernel: str | None = None
    initrd: str | None = None
    append: str | None = None
    machine_firmware: str | None = None

    # UEFI via pflash. Images that ship an EFI-bootable disk (LineageOS/GSI)
    # need these two instead of -kernel. `code` is read-only firmware,
    # `vars` is the writable per-VM variable store.
    pflash_code: str | None = None
    pflash_vars: str | None = None

    # Block devices. Paths are absolute, resolved at create time.
    disk: str | None = None
    disk_size_gb: int = 8
    cdrom: str | None = None

    # Explicit disk list; takes precedence over `disk`.
    # [{"id": "vda", "file": "...qcow2", "bootindex": 0, "format": "qcow2"}]
    disks: list[dict] = field(default_factory=list)

    # Host -> guest port forwarding, e.g. "tcp:127.0.0.1:5555-:5555"
    hostfwd: list[str] = field(default_factory=list)

    # Kept for the SSH bring-up path; folded into hostfwd when building argv.
    ssh_port: int | None = None

    gpu: bool = True
    headless: bool = True
    # Attach a virtio touchscreen. Games and some system dialogs only react to
    # touch events, ignoring mouse-button events entirely.
    touch: bool = True

    # QEMU's built-in VNC server, as a display *port* (5900 + display). This is
    # the C-plan display path: QEMU pushes only damaged rectangles, compressed
    # with ZRLE, instead of the UI asking for a full-screen `screendump` 30
    # times a second. Measured on a scrolling guest: 0.38 MB/s vs ~90 MB/s.
    # None means "no VNC"; the GUI then falls back to screendump polling.
    vnc_display: int | None = None

    # Escape hatch for experiments. Not part of the product surface.
    extra_args: list[str] = field(default_factory=list)

    def to_dict(self) -> dict:
        return asdict(self)

    def save(self, path: Path) -> None:
        path.write_text(json.dumps(self.to_dict(), indent=2, ensure_ascii=False) + "\n")

    @classmethod
    def load(cls, path: Path) -> "VMConfig":
        raw = json.loads(path.read_text())
        known = {f for f in cls.__dataclass_fields__}
        return cls(**{k: v for k, v in raw.items() if k in known})
