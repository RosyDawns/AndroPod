"""Import the community LineageOS QEMU image as an AndroPod instance.

Source: https://github.com/jqssun/android-lineage-qemu — LineageOS (Android 16)
built specifically for the QEMU `virt` board, packaged as a UTM bundle.

Design note: the base disks are large (~1 GB). Each instance gets a thin qcow2
overlay backed by the base image, so N instances cost almost nothing extra and
the base stays pristine.
"""

from __future__ import annotations

import glob
import subprocess
import zipfile
from pathlib import Path

from .config import VMConfig
from .vm import qemu_img_binary

EDK2_CANDIDATES = [
    "/opt/homebrew/share/qemu/edk2-aarch64-code.fd",
    "/usr/local/share/qemu/edk2-aarch64-code.fd",
    "/opt/homebrew/Cellar/qemu/*/share/qemu/edk2-aarch64-code.fd",
    "/usr/share/AAVMF/AAVMF_CODE.fd",
    "/usr/share/qemu-efi-aarch64/QEMU_EFI.fd",
]

# Ports the image expects: 5555 adbd, 5554 fastbootd.
DEFAULT_HOSTFWD = [
    "tcp:127.0.0.1:5555-:5555",
    "tcp:127.0.0.1:5554-:5554",
]

# QEMU's pflash device requires the variable store to match the firmware's
# expected size exactly — Homebrew's edk2-aarch64-code.fd wants 64 MiB. The UTM
# bundle ships a 327 KiB store built for UTM's own firmware, which QEMU rejects.
PFLASH_VARS_SIZE = 64 * 1024 * 1024


class ImportError_(RuntimeError):
    pass


def find_edk2_code() -> Path:
    for pattern in EDK2_CANDIDATES:
        for match in glob.glob(pattern):
            return Path(match)
    raise ImportError_("找不到 edk2-aarch64-code.fd，请确认 qemu 已安装")


def unpack(zip_path: Path, dest: Path) -> Path:
    """Extract the UTM bundle and return the directory holding efi_vars.fd."""
    dest.mkdir(parents=True, exist_ok=True)
    marker = dest / ".unpacked"
    if not marker.exists():
        print(f"  解压 {zip_path.name} …")
        with zipfile.ZipFile(zip_path) as archive:
            archive.extractall(dest)
        marker.write_text("ok\n")

    for data_dir in sorted(dest.glob("**/*.utm/Data")):
        if (data_dir / "efi_vars.fd").exists():
            return data_dir

    # Tolerate a flat layout too.
    for candidate in (dest, dest / "Data"):
        if (candidate / "efi_vars.fd").exists():
            return candidate

    raise ImportError_(f"在 {dest} 中找不到 .utm/Data/efi_vars.fd，压缩包结构不符合预期")


def create_overlay(base: Path, overlay: Path) -> Path:
    """Thin qcow2 layer on top of a read-only base disk."""
    overlay.parent.mkdir(parents=True, exist_ok=True)
    if overlay.exists():
        return overlay
    subprocess.run(
        [
            qemu_img_binary(), "create", "-f", "qcow2",
            "-F", "qcow2", "-b", str(base), str(overlay),
        ],
        check=True,
        capture_output=True,
    )
    return overlay


def build_config(
    name: str,
    data_dir: Path,
    workdir: Path,
    memory_mb: int,
    cpus: int,
) -> VMConfig:
    cfg = VMConfig(name=name, cpus=cpus, memory_mb=memory_mb)

    cfg.pflash_code = str(find_edk2_code())
    # qcow2, not raw: `savevm` refuses to snapshot a writable raw device, and the
    # UEFI variable store is the only remaining raw device once the disks are
    # qcow2. Without this, full-state snapshots are impossible.
    vars_target = workdir / "efi_vars.qcow2"
    if not vars_target.exists():
        subprocess.run(
            [qemu_img_binary(), "create", "-f", "qcow2", str(vars_target), "64M"],
            check=True,
            capture_output=True,
        )
    cfg.pflash_vars = str(vars_target)

    disks: list[dict] = []
    base_disks = sorted(data_dir.glob("vd*.qcow2"))
    if not base_disks:
        raise ImportError_(f"{data_dir} 中没有 vd*.qcow2")

    for index, base in enumerate(base_disks):
        disk_id = base.stem  # vda, vdb
        overlay = create_overlay(base, workdir / f"{disk_id}.qcow2")
        disks.append(
            {
                "id": disk_id,
                "file": str(overlay),
                "bootindex": index,
                "format": "qcow2",
            }
        )
    cfg.disks = disks
    cfg.hostfwd = list(DEFAULT_HOSTFWD)
    cfg.disk = None
    return cfg
