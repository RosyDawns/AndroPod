"""Guest image acquisition.

Phase 0 needs *a* bootable arm64 guest to prove the control plane works. Alpine's
netboot assets are the cheapest option: ~19MB total, serial console works out of
the box, no cloud-init, no ISO bootloader, and — critically — no CD-ROM device,
which means internal VM snapshots can include full RAM state.

The real Android image is a separate and much harder problem. See docs/03-roadmap.md.
"""

from __future__ import annotations

import sys
import urllib.request
from pathlib import Path

ALPINE_NETBOOT = "https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/aarch64/netboot/"
ALPINE_REPO = "https://dl-cdn.alpinelinux.org/alpine/latest-stable/main"

KERNEL_FILE = "vmlinuz-virt"
INITRD_FILE = "initramfs-virt"
MODLOOP_FILE = "modloop-virt"


def alpine_append() -> str:
    """Kernel cmdline for the Alpine netboot guest."""
    return " ".join(
        [
            "console=ttyAMA0",
            "modules=loop,squashfs,sd-mod",
            f"alpine_repo={ALPINE_REPO}",
            f"modloop={ALPINE_NETBOOT}{MODLOOP_FILE}",
        ]
    )


def download(url: str, target: Path, label: str = "") -> Path:
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists() and target.stat().st_size > 0:
        print(f"[skip] {target.name}  ({target.stat().st_size // 1024} KB)")
        return target

    tmp = target.with_suffix(target.suffix + ".part")
    request = urllib.request.Request(url, headers={"User-Agent": "andropod/0.1"})
    with urllib.request.urlopen(request, timeout=60) as response, open(tmp, "wb") as out:
        total = int(response.headers.get("Content-Length") or 0)
        done = 0
        while chunk := response.read(1 << 20):
            out.write(chunk)
            done += len(chunk)
            if total:
                pct = done * 100 // total
                sys.stdout.write(
                    f"\r  下载 {label or target.name} {pct:3d}%  {done >> 20}MB / {total >> 20}MB"
                )
                sys.stdout.flush()
    sys.stdout.write("\n")
    tmp.replace(target)
    return target


def fetch_alpine_netboot(images_dir: Path) -> tuple[Path, Path]:
    kernel = download(ALPINE_NETBOOT + KERNEL_FILE, images_dir / KERNEL_FILE)
    initrd = download(ALPINE_NETBOOT + INITRD_FILE, images_dir / INITRD_FILE)
    return kernel, initrd
