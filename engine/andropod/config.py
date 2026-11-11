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

    # MuMu-style direct kernel boot: the engine starts the extracted GKI
    # kernel itself and OWNS the kernel cmdline — no EDK2, no GRUB, no
    # grubenv. Requires runtime/images/boot-assets/{kernel,initrd.img};
    # falls back to the UEFI/GRUB pflash path when absent or disabled.
    # The two switches below are per-instance USER choices (GUI settings),
    # defaulting to the image's own secure state — they only take effect
    # when explicitly enabled.
    direct_boot: bool = True
    insecure_adb: bool = False
    selinux_permissive: bool = False

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
    # "2d" (default): virtio-gpu-pci, guest renders with SwiftShader.
    #   The default is chosen for *recoverability*, not raw speed: it is the
    #   only backend that can save and restore VM state. virgl answers
    #   `savevm` with "virgl is not yet migratable" (E15), so a virgl instance
    #   can never be resumed — it always pays a 30-40 s cold boot and can never
    #   land straight on the launcher the way MuMu does. It also needs no
    #   security relaxation: apps keep their own SELinux domain.
    # "virgl": virtio-gpu-gl-pci from the qemu-virgl build — guest GLES goes
    #   through Mesa/virgl to the host GPU. E11 measured 60 FPS / 11-13 ms GPU
    #   frame time on a commercial Unity title, versus SwiftShader on 2D. It
    #   needs a permissive SELinux in the guest (udmabuf access from app
    #   processes, E9/E13); that switch stays a per-instance user choice, and
    #   turning it on forfeits snapshots.
    gpu_backend: str = "2d"

    # Preferred guest display geometry. xres/yres are passed to virtio-gpu-pci
    # (2D backend) as the initial surface size; dpi is metadata the UI shows
    # (MuMu-style "1600 × 945 | 236 DPI"). The virgl backend pins its own mode
    # with edid=off (E10), so xres/yres currently only apply to the 2D backend.
    xres: int | None = None
    yres: int | None = None
    dpi: int | None = None

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
        # Drop nulls. An instance.json written before a field existed (or
        # while it was still optional) can carry an explicit null, and passing
        # None through would *override* the dataclass default — which is how
        # `"gpu_backend": null` silently pinned old instances to SwiftShader
        # long after virgl became the default.
        return cls(**{
            k: v for k, v in raw.items() if k in known and v is not None
        })
