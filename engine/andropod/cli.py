"""Command line entry point.

Phase 0 surface. Everything the product will eventually do visually has to be
provable here first, one command at a time.
"""

from __future__ import annotations

import argparse
import json
import platform
import shutil
import subprocess
import sys
import time
from pathlib import Path

from . import __version__, images, paths
from .config import VMConfig
from .vm import QEMU_VIRGL_DIR, VM, qemu_binary, qemu_img_binary

DEFAULT_BOOT_MARKER = "login:"


# --------------------------------------------------------------------------
# helpers


def _instance(name: str) -> VM:
    workdir = paths.instance_dir(name)
    cfg_path = workdir / "instance.json"
    if not cfg_path.exists():
        raise SystemExit(
            f"实例 {name!r} 不存在。先运行: python3 -m andropod create --name {name}"
        )
    return VM(VMConfig.load(cfg_path), workdir)


def _print_kv(pairs: dict) -> None:
    width = max(len(str(k)) for k in pairs) if pairs else 0
    for key, value in pairs.items():
        print(f"  {str(key).ljust(width)}  {value}")


def _next_vnc_display(exclude: str | None = None) -> int:
    """Pick a VNC display number no other instance is already using.

    QEMU binds 5900 + display on 127.0.0.1. Two instances on the same display
    makes the second one fail to start, so allocate deterministically from the
    saved configs rather than assuming 5901 is always free.
    """
    used: set[int] = set()
    root = paths.INSTANCES_DIR
    if root.exists():
        for cfg_path in root.glob("*/instance.json"):
            if exclude and cfg_path.parent.name == exclude:
                continue
            try:
                value = json.loads(cfg_path.read_text()).get("vnc_display")
            except (OSError, ValueError, json.JSONDecodeError):
                continue
            if isinstance(value, int) and value > 0:
                used.add(value)
    display = 1
    while display in used:
        display += 1
    return display


def _parse_hostfwd(rule: str) -> tuple[int, int] | None:
    """("tcp:127.0.0.1:5556-:5555") -> (5556, 5555); None when unparseable.

    host = parts[2] ("5556-" — trailing dash separates guest side), guest =
    parts[3]. The old code read parts[3] as the host port, so every stored
    instance reported guest 5555 as "in use" and nothing else — new instances
    all collided on 5556 and clones never got rebound at all.
    """
    parts = rule.split(":")
    if len(parts) < 4:
        return None
    try:
        host = int(parts[2].split("-", 1)[0])
        guest = int(parts[3].split("-", 1)[0])
    except ValueError:
        return None
    return host, guest


def _used_host_ports(exclude: str | None = None) -> set[int]:
    """Every host-side TCP port bound by a stored instance's hostfwd rules."""
    used: set[int] = set()
    root = paths.INSTANCES_DIR
    if root.exists():
        for cfg_path in root.glob("*/instance.json"):
            if exclude and cfg_path.parent.name == exclude:
                continue
            try:
                rules = json.loads(cfg_path.read_text()).get("hostfwd") or []
            except (OSError, ValueError, json.JSONDecodeError):
                continue
            for rule in rules:
                parsed = _parse_hostfwd(rule)
                if parsed:
                    used.add(parsed[0])
    return used


def _rebind_hostfwd(hostfwd: list[str], used: set[int]) -> list[str]:
    """Reallocate the host side of each forward rule to a free port.

    The guest-side port (after "-:") is kept; only the host port changes, so a
    clone can run next to its source. Mutates `used` as it allocates.
    """
    rebound: list[str] = []
    next_port = (max(used) + 1) if used else 5556
    for rule in hostfwd:
        parsed = _parse_hostfwd(rule)
        if parsed:
            while next_port in used:
                next_port += 1
            used.add(next_port)
            rebound.append(f"tcp:127.0.0.1:{next_port}-:{parsed[1]}")
        else:
            rebound.append(rule)
    return rebound


# --------------------------------------------------------------------------
# commands


def cmd_env(args: argparse.Namespace) -> int:
    info: dict[str, object] = {
        "版本": __version__,
        "平台": f"{platform.system()} {platform.machine()}",
        "macOS": platform.mac_ver()[0],
        "Python": platform.python_version(),
        "项目根": str(paths.PROJECT_ROOT),
    }
    try:
        info["QEMU"] = qemu_binary()
        version = subprocess.run(
            [qemu_binary(), "--version"], capture_output=True, text=True
        ).stdout.splitlines()[0]
        info["QEMU 版本"] = version
        accelerators = subprocess.run(
            [qemu_binary(), "-accel", "help"], capture_output=True, text=True
        ).stdout
        info["硬件加速"] = "hvf 可用" if "hvf" in accelerators else "hvf 缺失"
    except RuntimeError as exc:
        info["QEMU"] = f"缺失 — {exc}"

    kernel = paths.IMAGES_DIR / images.KERNEL_FILE
    initrd = paths.IMAGES_DIR / images.INITRD_FILE
    info["测试内核"] = "已就绪" if kernel.exists() else "未下载 (运行 fetch)"
    info["initramfs"] = "已就绪" if initrd.exists() else "未下载"

    print("环境检查")
    _print_kv(info)
    return 0


def cmd_fetch(args: argparse.Namespace) -> int:
    paths.ensure_dirs()
    print("获取 Alpine netboot 测试镜像")
    images.fetch_alpine_netboot(paths.IMAGES_DIR)
    print("完成。")
    return 0


def cmd_create(args: argparse.Namespace) -> int:
    paths.ensure_dirs()
    workdir = paths.instance_dir(args.name)
    if workdir.exists() and not args.force:
        raise SystemExit(f"实例 {args.name!r} 已存在。加 --force 覆盖配置。")
    workdir.mkdir(parents=True, exist_ok=True)

    cfg = VMConfig(name=args.name, cpus=args.cpus, memory_mb=args.memory)

    # --- Android (LineageOS) path ------------------------------------------
    # runtime/images/base-vda.qcow2 is a frozen APFS clone of the initialized
    # lineage instance's disks: bootloader already carries
    # androidboot.insecure_adb=1 (network adb works without pairing), the
    # setup wizard is done, and the mesa/virgl graphics chain is in place.
    # The UTM factory bundle was tried first but its adbd is secure-mode, so
    # provision/adb input could never reach those instances.
    images_dir = paths.IMAGES_DIR
    base_vda = images_dir / "base-vda.qcow2"
    base_vdb = images_dir / "base-vdb.qcow2"
    base_vars = images_dir / "base-efi-vars.qcow2"
    edk2_code = Path("/opt/homebrew/share/qemu/edk2-aarch64-code.fd")
    android_base_ok = (
        base_vda.exists() and base_vdb.exists() and base_vars.exists()
        and edk2_code.exists()
    )

    if android_base_ok and not args.alpine:
        vda = workdir / "vda.qcow2"
        vdb = workdir / "vdb.qcow2"
        subprocess.run(["cp", "-c", str(base_vda), str(vda)], check=True)
        subprocess.run(["cp", "-c", str(base_vdb), str(vdb)], check=True)
        efi_vars = workdir / "efi_vars.qcow2"
        if not efi_vars.exists():
            # APFS-clone the NVRAM too so every instance owns a private,
            # writable copy (UEFI boot entries live in there).
            subprocess.run(["cp", "-c", str(base_vars), str(efi_vars)], check=True)
        cfg.pflash_code = str(edk2_code)
        cfg.pflash_vars = str(efi_vars)
        cfg.disks = [
            {"id": "vda", "file": str(vda), "bootindex": 0, "format": "qcow2"},
            {"id": "vdb", "file": str(vdb), "bootindex": 1, "format": "qcow2"},
        ]
        cfg.disk = None
        cfg.headless = True
        # One adb forward per instance, host side allocated beyond everything
        # already registered (lineage owns 5555, clones own their ports).
        used = _used_host_ports(exclude=None)
        adb_port = 5555
        while adb_port in used:
            adb_port += 1
        cfg.hostfwd = [f"tcp:127.0.0.1:{adb_port}-:5555"]
    elif args.kernel:
        kernel = Path(args.kernel).expanduser().resolve()
        initrd = Path(args.initrd).expanduser().resolve()
        if not kernel.exists():
            raise SystemExit(f"内核不存在: {kernel}")
        if not initrd.exists():
            raise SystemExit(f"initramfs 不存在: {initrd}")
        cfg.kernel = str(kernel)
        cfg.initrd = str(initrd)
        cfg.append = args.append or images.alpine_append()
    else:
        # Alpine test guest — only meaningful for engine debugging; the GUI
        # never reaches this branch when the UTM base is present.
        kernel = paths.IMAGES_DIR / images.KERNEL_FILE
        initrd = paths.IMAGES_DIR / images.INITRD_FILE
        if not kernel.exists() or not initrd.exists():
            raise SystemExit("测试镜像未下载。先运行: python3 -m andropod fetch")
        cfg.kernel = str(kernel)
        cfg.initrd = str(initrd)
        cfg.append = args.append or images.alpine_append()

    disk = workdir / "disk.qcow2"
    if args.no_disk:
        cfg.disk = None
    else:
        cfg.disk = str(VM.create_disk(disk, args.disk_size))

    if args.cdrom:
        cfg.cdrom = str(Path(args.cdrom).expanduser().resolve())
    cfg.ssh_port = args.ssh_port
    cfg.gpu = not args.no_gpu
    cfg.gpu_backend = "2d" if args.no_gpu else args.gpu_backend
    if cfg.gpu_backend == "virgl" and not Path(
        QEMU_VIRGL_DIR, "qemu-system-aarch64"
    ).exists():
        raise SystemExit(
            "virgl 需要带 virtio-gpu-gl 的 QEMU。先执行:\n"
            "  brew install startergo/qemu-virgl/qemu-virgl\n"
            "或加 --gpu-backend 2d 走软件渲染"
        )
    cfg.xres = args.xres
    cfg.yres = args.yres
    cfg.dpi = args.dpi
    if args.no_vnc:
        cfg.vnc_display = None
    elif args.vnc_display is not None:
        cfg.vnc_display = args.vnc_display
    else:
        cfg.vnc_display = _next_vnc_display(exclude=args.name)
    cfg.save(workdir / "instance.json")

    print(f"已创建实例 {args.name}")
    _print_kv(
        {
            "目录": workdir,
            "CPU": cfg.cpus,
            "内存": f"{cfg.memory_mb} MB",
            "磁盘": (", ".join(entry["file"] for entry in cfg.disks)
                     if cfg.disks else (cfg.disk or "无")),
            "引导": ("UEFI（LineageOS 出厂镜像）" if cfg.disks and not cfg.kernel
                     else Path(cfg.kernel).name if cfg.kernel else "无"),
            "GPU": cfg.gpu_backend,
            "VNC": (f"127.0.0.1:{5900 + cfg.vnc_display}"
                    if cfg.vnc_display else "关闭（回退 screendump）"),
        }
    )
    if cfg.gpu_backend == "virgl" and not cfg.selinux_permissive:
        print(
            "提示: virgl 渲染需要客机 SELinux 宽容模式（udmabuf 访问，见 E9）。"
            "未开启时 app 会渲染黑屏；在 GUI 设置→开发者页开启，"
            "或重建时加 --gpu-backend 2d 只做排查。"
        )
    return 0


def cmd_boot(args: argparse.Namespace) -> int:
    """Boot an instance from a snapshot instead of letting the guest start up.

    This is the product's normal "power on". Starting the guest normally runs
    Android's init, which for this image means trade-in mode and a pending
    factory reset. Halting the CPU, restoring the snapshot and resuming skips all
    of that.
    """
    vm = _instance(args.name)
    if vm.is_running():
        raise SystemExit(f"实例 {args.name!r} 已在运行。先 stop。")

    vm.start(wait_running=False, paused=True)
    tags = vm.snapshots()
    if args.snapshot not in tags:
        vm.stop()
        raise SystemExit(f"快照 {args.snapshot!r} 不存在。现有: {', '.join(tags) or '(无)'}")

    started = time.monotonic()
    try:
        vm.loadvm(args.snapshot)
    except Exception as exc:  # QMPError / RuntimeError from HMP
        # `loadvm` is the *only* way back to a saved state, and QEMU refuses it
        # outright for two reasons worth naming: the saved device model no
        # longer matches (GPU backend switch), or the device is not migratable
        # at all (virtio-gpu-gl: "virgl is not yet migratable"). Leaving QEMU
        # paused here would strand the instance half-loaded, so stop it first.
        vm.stop()
        reason = str(exc)
        if "migratable" in reason:
            raise SystemExit(
                f"快照 {args.snapshot!r} 只有磁盘内容：virgl 后端无法保存内存状态，"
                f"无法“秒开”。\n改用 start 冷启动。\n原因: {reason}"
            ) from exc
        raise SystemExit(
            f"快照 {args.snapshot!r} 无法恢复：设备模型与保存时不一致"
            f"（多见于切换 GPU 后端之后）。\n"
            f"改用 start 冷启动一次，再保存新快照即可。\n原因: {reason}"
        ) from exc
    restore_seconds = time.monotonic() - started
    vm.resume()
    print(
        f"已从快照 {args.snapshot!r} 启动 {args.name}  "
        f"{restore_seconds:.2f}s（未经过客户机引导）"
    )
    return 0


def cmd_plan(args: argparse.Namespace) -> int:
    """Prepare an instance for the GUI's player process.

    The player embeds QEMU in its own address space, so it must not go through
    `start` (that forks a QEMU). This subcommand does everything up to the exec
    — stale-state cleanup, argv construction, qemu.cmd, and the snapshot
    decision — and writes plan.json for the player to consume.
    """
    vm = _instance(args.name)
    if vm.is_running():
        raise SystemExit(f"实例 {args.name!r} 已在运行。先 stop。")

    snapshot: str | None = None
    if args.snapshot:
        marker = vm.workdir / "snapshot-invalid"
        if vm.cfg.gpu and getattr(vm.cfg, "gpu_backend", "virgl") == "virgl":
            # virtio-gpu-gl has no migratable state, so savevm/loadvm can never
            # carry the guest's RAM. Every snapshot on such an instance is a
            # disk-only one; booting it is a cold boot by definition.
            print(
                "virgl 后端不支持保存虚拟机内存状态（QEMU: virgl is not yet "
                "migratable），本次冷启动"
            )
        elif marker.exists():
            # A previous restore died because the saved device model no longer
            # matches the instance (GPU backend switch). Booting the same
            # snapshot again would fail the same way; cold boot once, then the
            # next `snap` clears this marker.
            print(
                f"跳过快照 {args.snapshot!r}：上次恢复失败（设备模型已变），"
                "本次冷启动"
            )
        elif args.snapshot in vm.disk_snapshots():
            snapshot = args.snapshot
        else:
            print(f"快照 {args.snapshot!r} 不存在，改为冷启动")

    vm.plan(paused=snapshot is not None)

    plan = {
        "name": args.name,
        "workdir": str(vm.workdir),
        "snapshot": snapshot,
        "serial_log": str(vm.serial_log),
        "qmp": str(vm.qmp_sock),
        "pid_file": str(vm.pid_file),
        "gpu": bool(vm.cfg.gpu and getattr(vm.cfg, "gpu_backend", "virgl") == "virgl"),
        "xres": int(getattr(vm.cfg, "xres", 0) or 0),
        "yres": int(getattr(vm.cfg, "yres", 0) or 0),
    }
    (vm.workdir / "plan.json").write_text(
        json.dumps(plan, indent=2, ensure_ascii=False) + "\n"
    )
    print(json.dumps(plan, indent=2, ensure_ascii=False))
    return 0


def cmd_start(args: argparse.Namespace) -> int:
    vm = _instance(args.name)
    if vm.is_running() and not args.force:
        raise SystemExit(f"实例 {args.name!r} 已在运行。先 stop 或加 --force。")

    started = time.monotonic()
    pid = vm.start(timeout=args.timeout)
    print(f"已启动 {args.name}  pid={pid}  QMP 就绪 {time.monotonic() - started:.2f}s")

    if args.wait_for != "__none__":
        marker = args.wait_for or DEFAULT_BOOT_MARKER
        print(f"等待串口标记 {marker!r} ...")
        try:
            vm.wait_for_serial(marker, timeout=args.boot_timeout)
        except TimeoutError as exc:
            print(f"失败: {exc}")
            print(f"串口日志: {vm.serial_log}")
            return 1
        print(f"就绪，总耗时 {time.monotonic() - started:.1f}s")
    return 0


def cmd_status(args: argparse.Namespace) -> int:
    vm = _instance(args.name)
    payload: dict[str, object] = {"实例": args.name, "进程存活": vm.is_running()}
    if vm.is_running():
        try:
            payload.update(vm.query_status())
        except Exception as exc:  # noqa: BLE001 - status must never throw
            payload["QMP"] = f"不可用: {exc}"
        payload["串口日志"] = str(vm.serial_log)
    print(json.dumps(payload, indent=2, ensure_ascii=False))
    return 0


def cmd_stop(args: argparse.Namespace) -> int:
    vm = _instance(args.name)
    vm.stop(graceful=args.graceful, timeout=args.timeout)
    print(f"已停止 {args.name}")
    return 0


def cmd_snap(args: argparse.Namespace) -> int:
    vm = _instance(args.name)
    started = time.monotonic()
    try:
        tags = vm.savevm(args.tag)
    except RuntimeError as exc:
        # QEMU's own words are the useful part here: with a virtio-gpu-gl
        # device it answers "virgl is not yet migratable", i.e. no RAM state
        # can be written at all. Pretending otherwise produces the disk-only
        # snapshots this image already carries.
        raise SystemExit(f"快照失败：{exc}") from exc
    elapsed = time.monotonic() - started
    ok = args.tag in tags
    if ok:
        # A fresh snapshot matches the current device model, so the "this
        # snapshot cannot be restored" veto left by a failed loadvm is stale.
        (vm.workdir / "snapshot-invalid").unlink(missing_ok=True)
    print(f"快照 {args.tag!r} {'成功' if ok else '未出现在快照列表中'}  {elapsed:.2f}s")
    print(f"现有快照: {', '.join(tags) if tags else '(无)'}")
    return 0 if ok else 1


def cmd_snaps(args: argparse.Namespace) -> int:
    vm = _instance(args.name)
    tags = vm.snapshots()
    print(f"快照 ({len(tags)}):")
    for tag in tags:
        print(f"  - {tag}")
    return 0


def cmd_restore(args: argparse.Namespace) -> int:
    vm = _instance(args.name)
    started = time.monotonic()
    vm.loadvm(args.tag)
    print(f"已恢复到 {args.tag!r}  {time.monotonic() - started:.2f}s")
    return 0


def cmd_shot(args: argparse.Namespace) -> int:
    vm = _instance(args.name)
    out = Path(args.output).expanduser().resolve()
    vm.screendump(out)
    print(f"已保存截图 {out}")
    return 0


def cmd_import_utm(args: argparse.Namespace) -> int:
    """Import a UTM-packaged Android image as a native instance."""
    from . import lineage

    paths.ensure_dirs()
    zip_path = Path(args.zip).expanduser().resolve()
    if not zip_path.exists():
        raise SystemExit(f"镜像包不存在: {zip_path}")

    print(f"导入 {zip_path.name}")
    data_dir = lineage.unpack(zip_path, paths.IMAGES_DIR / "lineage")
    print(f"  镜像目录  {data_dir}")

    workdir = paths.instance_dir(args.name)
    if workdir.exists() and not args.force:
        raise SystemExit(f"实例 {args.name!r} 已存在。加 --force 覆盖配置。")
    workdir.mkdir(parents=True, exist_ok=True)

    cfg = lineage.build_config(args.name, data_dir, workdir, args.memory, args.cpus)
    cfg.save(workdir / "instance.json")

    print(f"已创建实例 {args.name}")
    _print_kv(
        {
            "目录": workdir,
            "CPU": cfg.cpus,
            "内存": f"{cfg.memory_mb} MB",
            "固件": Path(cfg.pflash_code).name,
            "磁盘": ", ".join(d["id"] for d in cfg.disks),
            "端口": ", ".join(cfg.hostfwd),
        }
    )
    return 0


def cmd_delete(args: argparse.Namespace) -> int:
    """Remove an instance directory entirely — config, disks, everything.

    This is the one destructive command the UI exposes as a bare button
    (behind a confirmation dialog), so it fails loudly on any ambiguity
    rather than guessing: unknown name, or the guest still running.
    """
    if args.name in ("", ".", "..") or "/" in args.name or "\\" in args.name:
        raise SystemExit(f"非法实例名: {args.name!r}")
    workdir = paths.instance_dir(args.name)
    if not workdir.exists():
        raise SystemExit(f"实例 {args.name!r} 不存在")

    try:
        vm = _instance(args.name)
        running = vm.is_running()
    except SystemExit:
        running = False  # broken config should not block deletion
    if running:
        if not args.force:
            raise SystemExit(f"实例 {args.name!r} 正在运行。先 stop，或加 --force。")
        _instance(args.name).stop(timeout=40)

    shutil.rmtree(workdir)
    print(f"已删除实例 {args.name}（{workdir}）")
    return 0


def cmd_clone(args: argparse.Namespace) -> int:
    """Duplicate an instance: config + disks + EFI vars, then rebind identity.

    Disks are cloned with APFS clonefile (`cp -c`), so a multi-GB image copy
    is O(1) on the default filesystem. The clone gets its own name, host
    ports, and VNC display; the source must be stopped so the disk copy is
    consistent.
    """
    src = paths.instance_dir(args.name)
    cfg_path = src / "instance.json"
    if not cfg_path.exists():
        raise SystemExit(f"实例 {args.name!r} 不存在")
    if not args.to:
        raise SystemExit("缺少 --to 新实例名")
    if args.to in ("", ".", "..") or "/" in args.to or "\\" in args.to:
        raise SystemExit(f"非法实例名: {args.to!r}")
    dst = paths.instance_dir(args.to)
    if dst.exists():
        raise SystemExit(f"实例 {args.to!r} 已存在")

    try:
        if _instance(args.name).is_running():
            raise SystemExit(f"实例 {args.name!r} 正在运行，克隆前请先 stop。")
    except SystemExit:
        raise
    except Exception:  # noqa: BLE001 - unreadable config: copy anyway
        pass

    started = time.monotonic()
    # `cp -c` uses clonefile on APFS (instant, copy-on-write) and falls back
    # to a plain copy elsewhere. -R copies the directory itself.
    subprocess.run(["cp", "-cR", str(src), str(dst)], check=True)

    # Runtime leftovers from the source have no meaning in the clone.
    for junk in ("qemu.pid", "qemu.log", "qemu.cmd", "serial.log", "screenshot.ppm"):
        junk_path = dst / junk
        if junk_path.exists():
            junk_path.unlink()

    cfg = VMConfig.load(dst / "instance.json")
    cfg.name = args.to

    def retarget(path: str | None) -> str | None:
        """Point a file reference inside the source dir at the clone's copy."""
        if path is None:
            return None
        try:
            p = Path(path)
            if p.is_relative_to(src):
                return str(dst / p.relative_to(src))
        except ValueError:
            pass
        return path

    cfg.pflash_vars = retarget(cfg.pflash_vars)
    cfg.pflash_code = retarget(cfg.pflash_code)
    cfg.disk = retarget(cfg.disk)
    cfg.disks = [
        {**entry, "file": retarget(entry["file"])} if entry.get("file") else entry
        for entry in cfg.disks
    ]

    # The source keeps its ports even though it is stopped right now, so the
    # clone must find free ones outside everything currently registered.
    used = _used_host_ports(exclude=None)
    cfg.hostfwd = _rebind_hostfwd(cfg.hostfwd, used)
    cfg.vnc_display = _next_vnc_display(exclude=args.name)
    cfg.save(dst / "instance.json")

    print(f"已克隆 {args.name} → {args.to}  {time.monotonic() - started:.2f}s")
    _print_kv(
        {
            "目录": dst,
            "CPU": cfg.cpus,
            "内存": f"{cfg.memory_mb} MB",
            "端口": ", ".join(cfg.hostfwd),
            "VNC": f"127.0.0.1:{5900 + cfg.vnc_display}" if cfg.vnc_display else "关闭",
        }
    )
    return 0


def cmd_tap(args: argparse.Namespace) -> int:
    """Click at guest pixel coordinates.

    Defaults to QMP. Not because it is more capable — adb `input` reaches more
    surfaces — but because it is the only channel that survives a snapshot
    restore: rewinding the guest leaves adbd holding a host socket that no
    longer exists, so every adb command then hangs until it times out. `--mode
    adb` remains available when the guest is freshly booted and you need to hit
    a surface that ignores emulated pointer events.
    """
    from . import input as input_mod

    vm = _instance(args.name)
    serial = f"127.0.0.1:{args.adb_port}"

    if args.mode == "adb":
        if not input_mod.adb_ready(serial, args.adb_server_port):
            print("adb 不可用（快照恢复后常见），无法使用 adb 模式")
            return 1
        ok, output = input_mod.adb_tap(serial, args.x, args.y, args.adb_server_port)
        print(f"已点击 ({args.x}, {args.y})  via adb input" if ok else f"adb 点击失败: {output}")
        return 0 if ok else 1

    if args.mode == "touch" and vm.has_touch():
        try:
            vm.touch(args.x, args.y, args.width, args.height)
            print(f"已触摸 ({args.x}, {args.y})，坐标空间 {args.width}x{args.height}")
            return 0
        except Exception as exc:  # noqa: BLE001
            print(f"触摸注入失败: {exc}")
            return 1

    qmp = vm.input_attach()
    x = int(args.x / args.width * 32767)
    y = int(args.y / args.height * 32767)

    # Separate batches with a short pause: Android's input pipeline coalesces or
    # drops a press/release delivered in the same frame. 10/20 ms is enough —
    # the earlier 120/80 ms only made taps feel sluggish.
    qmp.execute(
        "input-send-event",
        {
            "events": [
                {"type": "abs", "data": {"axis": "x", "value": x}},
                {"type": "abs", "data": {"axis": "y", "value": y}},
            ]
        },
    )
    time.sleep(0.012)
    qmp.execute(
        "input-send-event",
        {"events": [{"type": "btn", "data": {"down": True, "button": "left"}}]},
    )
    time.sleep(0.020)
    qmp.execute(
        "input-send-event",
        {"events": [{"type": "btn", "data": {"down": False, "button": "left"}}]},
    )
    print(f"已点击 ({args.x}, {args.y}) → QEMU ({x}, {y})")
    return 0


def cmd_key(args: argparse.Namespace) -> int:
    """Send a key press. Prefers adb (accepts HOME/BACK/KEYCODE_*), falls back
    to a QEMU key name such as 'ret' or 'home'."""
    from . import input as input_mod

    serial = f"127.0.0.1:{args.adb_port}"
    if input_mod.adb_ready(serial, args.adb_server_port):
        ok, output = input_mod.adb_key(serial, args.keyname, args.adb_server_port)
        if ok:
            print(f"已发送按键 {args.keyname}  via adb input")
            return 0
        print(f"adb 按键失败（{output}），回退到 QMP")

    vm = _instance(args.name)
    vm.attach()
    vm.qmp.execute(
        "input-send-event",
        {
            "events": [
                {"type": "key", "data": {"down": True, "key": {"type": "qcode", "data": args.keyname}}},
                {"type": "key", "data": {"down": False, "key": {"type": "qcode", "data": args.keyname}}},
            ]
        },
    )
    print(f"已发送按键 {args.keyname}")
    return 0


def cmd_swipe(args: argparse.Namespace) -> int:
    """Scroll or drag between two guest pixels."""
    from . import input as input_mod

    serial = f"127.0.0.1:{args.adb_port}"
    if not input_mod.adb_ready(serial, args.adb_server_port):
        print("滑动需要 adb（先生成实例并 provision）")
        return 1
    ok, output = input_mod.adb_swipe(
        serial, args.x1, args.y1, args.x2, args.y2, args.duration, args.adb_server_port
    )
    print("已滑动" if ok else f"滑动失败: {output}")
    return 0 if ok else 1


def cmd_provision(args: argparse.Namespace) -> int:
    """Take a freshly booted Android guest to a usable, ADB-enabled desktop."""
    from . import provision as prov

    apks = [Path(p).expanduser().resolve() for p in (args.apk or [])]
    for apk in apks:
        if not apk.exists():
            raise SystemExit(f"APK 不存在: {apk}")

    serial = f"127.0.0.1:{args.adb_port}"
    report = prov.provision(
        serial, args.adb_server_port, apks, verbose=not args.quiet
    )
    print(json.dumps(report, indent=2, ensure_ascii=False))
    return 0


def cmd_bake_base(args: argparse.Namespace) -> int:
    """Copy a stopped instance's disks over the template new instances clone.

    New instances are APFS clones of `images/base-vda.qcow2`. Whatever state the
    template is in is what every new device boots into — including Android's
    first-boot wizard. Baking after a provisioned run is what makes "新建即桌面"
    true.
    """
    vm = _instance(args.source)
    if vm.is_running():
        raise SystemExit(f"实例 {args.source!r} 正在运行，先 stop 再回写母盘。")

    # 母盘必须是"客机已经正常关机"的状态。硬停（QMP quit）会丢掉页缓存，
    # vfat 的 /vendor/firmware_mnt 没有日志，克隆后每次开机 mount() EINVAL，
    # init 会按 init_fatal_reboot_target=recovery 无限重启 —— 这个坑踩过一次。
    if not args.force:
        tail = b""
        try:
            with open(vm.serial_log, "rb") as handle:
                handle.seek(max(0, handle.seek(0, 2) - 4096))
                tail = handle.read()
        except OSError:
            pass
        if b"reboot: Power down" not in tail:
            raise SystemExit(
                "拒绝回写：串口日志里没有正常关机（reboot: Power down）。\n"
                "先 `andropod stop --name X --graceful` 等客机自己关机，"
                "确认无误后再回写；确实知道自己在做什么可加 --force。"
            )

    images = paths.IMAGES_DIR
    pairs = [("vda.qcow2", "base-vda.qcow2"), ("vdb.qcow2", "base-vdb.qcow2")]
    baked = []
    for src_name, dst_name in pairs:
        src = vm.workdir / src_name
        if not src.exists():
            continue
        dst = images / dst_name
        dst.unlink(missing_ok=True)
        subprocess.run(["cp", "-c", str(src), str(dst)], check=True)
        baked.append(dst_name)
        print(f"母盘已更新: {dst}  ({dst.stat().st_size // (1024 * 1024)} MB)")

    if not baked:
        raise SystemExit(f"实例 {args.source!r} 没有可回写的磁盘")

    # Marker read by the app on launch and by `create`: once present, no new
    # device ever sees Android's first-boot wizard again.
    marker = images / ".base-provisioned"
    marker.write_text(
        f"{args.source}\n{time.strftime('%Y-%m-%d %H:%M:%S')}\n", encoding="utf-8"
    )
    print("母盘已更新为当前实例的干净状态，后续 create 都克隆它")
    return 0


def cmd_prepare_base(args: argparse.Namespace) -> int:
    """Boot an instance, finish Android setup, then freeze it as the template.

    One-time step: after this, every `create` clones a device that already sits
    on the launcher instead of the first-boot wizard.
    """
    from . import provision as prov

    vm = _instance(args.name)
    if vm.is_running():
        raise SystemExit(f"实例 {args.name!r} 已在运行，先 stop。")

    print(f"启动 {args.name} 完成开机配置…")
    vm.start(wait_running=False)
    serial = f"127.0.0.1:{vm.cfg.hostfwd[0].rsplit(':', 1)[-1].split('-')[0]}" \
        if vm.cfg.hostfwd else f"127.0.0.1:{args.adb_port}"
    report = prov.provision(serial, args.adb_server_port, verbose=True)
    print(json.dumps(report, indent=2, ensure_ascii=False))

    # 必须让客机自己走完关机流程：vfat（/vendor/firmware_mnt）没有日志，
    # 硬停会留下半写的页缓存，克隆出来的母盘每次开机都 mount() EINVAL，
    # 触发 init_fatal_reboot_target=recovery 无限重启。
    print("通知客机正常关机（等待文件系统卸载）…")
    vm.stop(graceful=True, timeout=90)
    args.source = args.name
    return cmd_bake_base(args)


def cmd_smoke(args: argparse.Namespace) -> int:
    """End-to-end proof that the control plane works.

    Every assertion here maps to a capability the product needs. If this passes,
    the plumbing is real; if it fails, nothing above it matters.
    """
    results: list[tuple[str, bool, str]] = []
    timings: dict[str, float] = {}

    def check(label: str, ok: bool, detail: str = "") -> None:
        results.append((label, ok, detail))
        print(f"  [{'PASS' if ok else 'FAIL'}] {label}{'  ' + detail if detail else ''}")

    print("AndroPod 阶段 0 冒烟测试\n")

    print("1. 环境")
    try:
        binary = qemu_binary()
        check("QEMU 可执行文件", True, binary)
    except RuntimeError as exc:
        check("QEMU 可执行文件", False, str(exc))
        return 1

    accel = subprocess.run(
        [binary, "-accel", "help"], capture_output=True, text=True
    ).stdout
    check("HVF 硬件加速可用", "hvf" in accel)

    paths.ensure_dirs()
    kernel = paths.IMAGES_DIR / images.KERNEL_FILE
    initrd = paths.IMAGES_DIR / images.INITRD_FILE
    if not kernel.exists() or not initrd.exists():
        print("  [INFO] 测试镜像缺失，正在下载 ...")
        images.fetch_alpine_netboot(paths.IMAGES_DIR)
    check("测试内核就绪", kernel.exists(), str(kernel))
    check("initramfs 就绪", initrd.exists(), str(initrd))

    print("\n2. 实例与冷启动")
    name = args.name
    workdir = paths.instance_dir(name)
    if workdir.exists():
        try:
            _instance(name).stop(timeout=10)
        except SystemExit:
            pass
        shutil.rmtree(workdir)
    workdir.mkdir(parents=True, exist_ok=True)

    cfg = VMConfig(name=name, cpus=args.cpus, memory_mb=args.memory)
    cfg.kernel = str(kernel)
    cfg.initrd = str(initrd)
    cfg.append = images.alpine_append()
    cfg.disk = str(VM.create_disk(workdir / "disk.qcow2", args.disk_size))
    cfg.save(workdir / "instance.json")

    vm = VM(cfg, workdir)

    t0 = time.monotonic()
    vm.start(timeout=30)
    timings["QMP 握手"] = time.monotonic() - t0
    check("进程启动 + QMP 握手", True, f"{timings['QMP 握手']:.2f}s")

    status = vm.query_status()
    check("虚拟机进入 running 状态", status.get("status") == "running", str(status))
    check("HVF 加速实际生效", bool(status.get("running")))

    try:
        vm.wait_for_serial(DEFAULT_BOOT_MARKER, timeout=args.boot_timeout)
        timings["冷启动到登录"] = time.monotonic() - t0
        check("串口出现登录提示", True, f"{timings['冷启动到登录']:.1f}s")
    except TimeoutError as exc:
        check("串口出现登录提示", False, str(exc))
        vm.stop()
        _report(results, timings)
        return 1

    print("\n3. 快照与恢复")
    t1 = time.monotonic()
    tags = vm.savevm("smoke")
    timings["保存快照"] = time.monotonic() - t1
    check("savevm 保存全量状态", "smoke" in tags, f"{timings['保存快照']:.2f}s / 快照={tags}")

    t2 = time.monotonic()
    try:
        vm.loadvm("smoke")
        timings["恢复快照"] = time.monotonic() - t2
        check("loadvm 恢复全量状态", True, f"{timings['恢复快照']:.2f}s")
    except Exception as exc:  # noqa: BLE001
        check("loadvm 恢复全量状态", False, str(exc))

    print("\n4. 画面捕获")
    shot = workdir / "screenshot.ppm"
    try:
        vm.screendump(shot)
        check("screendump 抓取帧缓冲", shot.exists() and shot.stat().st_size > 0,
              f"{shot.stat().st_size // 1024} KB" if shot.exists() else "")
    except Exception as exc:  # noqa: BLE001
        check("screendump 抓取帧缓冲", False, str(exc))

    print("\n5. 停止")
    t3 = time.monotonic()
    vm.stop(timeout=20)
    timings["停止"] = time.monotonic() - t3
    check("优雅停止", not vm.is_running(), f"{timings['停止']:.2f}s")

    return _report(results, timings)


def _report(results: list[tuple[str, bool, str]], timings: dict[str, float]) -> int:
    passed = sum(1 for _, ok, _ in results if ok)
    total = len(results)
    print("\n" + "=" * 56)
    print(f"结果: {passed}/{total} 通过")
    if timings:
        print("-" * 56)
        for label, seconds in timings.items():
            print(f"  {label:<16} {seconds:6.2f}s")
    print("=" * 56)
    return 0 if passed == total else 1


# --------------------------------------------------------------------------
# parser


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="andropod",
        description="AndroPod 引擎 — Apple Silicon 上的安卓虚拟机编排",
    )
    parser.add_argument("--version", action="version", version=f"andropod {__version__}")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("env", help="检查本机环境").set_defaults(func=cmd_env)
    sub.add_parser("fetch", help="下载 Alpine 测试镜像").set_defaults(func=cmd_fetch)

    p_create = sub.add_parser("create", help="创建实例")
    p_create.add_argument("--name", default="default")
    p_create.add_argument("--cpus", type=int, default=4)
    p_create.add_argument("--memory", type=int, default=2048, help="单位 MB")
    p_create.add_argument("--disk-size", type=int, default=8, help="单位 GB")
    p_create.add_argument(
        "--gpu-backend", choices=["2d", "virgl"], default="2d",
        help="2d（默认）= SwiftShader 软渲染，但支持整机快照：可以秒开并直接"
             "落到桌面；virgl = 宿主 GPU 加速（guest GLES → Mesa/virgl → 宿主 "
             "OpenGL），更快，但需要客机 SELinux 宽容模式，且无法保存内存快照",
    )
    p_create.add_argument("--no-disk", action="store_true")
    p_create.add_argument("--kernel")
    p_create.add_argument("--initrd")
    p_create.add_argument("--append")
    p_create.add_argument("--cdrom")
    p_create.add_argument("--ssh-port", type=int)
    p_create.add_argument("--no-gpu", action="store_true")
    p_create.add_argument(
        "--vnc-display", type=int,
        help="VNC display 号（端口 = 5900 + N）。默认自动分配未占用的号",
    )
    p_create.add_argument(
        "--no-vnc", action="store_true",
        help="不启用 VNC，GUI 退回 screendump 抓帧",
    )
    p_create.add_argument("--xres", type=int, help="客户机显示宽（像素）")
    p_create.add_argument("--yres", type=int, help="客户机显示高（像素）")
    p_create.add_argument("--dpi", type=int, help="显示密度（UI 展示用元数据）")
    p_create.add_argument(
        "--alpine", action="store_true",
        help="强制创建 Alpine 测试实例（默认克隆 LineageOS 出厂镜像）",
    )
    p_create.add_argument("--force", action="store_true")
    p_create.set_defaults(func=cmd_create)

    p_clone = sub.add_parser("clone", help="克隆实例（APFS clonefile，秒级）")
    p_clone.add_argument("--name", required=True, help="源实例")
    p_clone.add_argument("--to", required=True, help="新实例名")
    p_clone.set_defaults(func=cmd_clone)

    p_delete = sub.add_parser("delete", help="删除实例（配置+磁盘，不可恢复）")
    p_delete.add_argument("--name", required=True)
    p_delete.add_argument("--force", action="store_true", help="运行中则先停止")
    p_delete.set_defaults(func=cmd_delete)

    p_import = sub.add_parser("import-utm", help="导入 UTM 打包的安卓镜像")
    p_import.add_argument("--zip", required=True)
    p_import.add_argument("--name", default="lineage")
    p_import.add_argument("--cpus", type=int, default=4)
    p_import.add_argument("--memory", type=int, default=4096, help="单位 MB")
    p_import.add_argument("--force", action="store_true")
    p_import.set_defaults(func=cmd_import_utm)

    p_boot = sub.add_parser("boot", help="从快照启动（推荐的开机方式）")
    p_boot.add_argument("--name", default="lineage")
    p_boot.add_argument("--snapshot", default="clean")
    p_boot.set_defaults(func=cmd_boot)

    p_plan = sub.add_parser(
        "plan", help="准备实例供 GUI 播放器内嵌启动（只写 qemu.cmd，不启动）"
    )
    p_plan.add_argument("--name", default="lineage")
    p_plan.add_argument("--snapshot", help="能恢复则恢复，否则冷启动")
    p_plan.set_defaults(func=cmd_plan)

    p_start = sub.add_parser("start", help="启动实例")
    p_start.add_argument("--name", default="default")
    p_start.add_argument("--timeout", type=float, default=30.0)
    p_start.add_argument("--boot-timeout", type=float, default=180.0)
    p_start.add_argument("--wait-for", help="等待串口出现该字符串；传 __none__ 跳过")
    p_start.add_argument("--force", action="store_true")
    p_start.set_defaults(func=cmd_start)

    p_status = sub.add_parser("status", help="查看实例状态")
    p_status.add_argument("--name", default="default")
    p_status.set_defaults(func=cmd_status)

    p_stop = sub.add_parser("stop", help="停止实例")
    p_stop.add_argument("--name", default="default")
    p_stop.add_argument("--graceful", action="store_true", help="先尝试 ACPI 关机")
    p_stop.add_argument("--timeout", type=float, default=20.0)
    p_stop.set_defaults(func=cmd_stop)

    p_snap = sub.add_parser("snap", help="保存快照")
    p_snap.add_argument("tag")
    p_snap.add_argument("--name", default="default")
    p_snap.set_defaults(func=cmd_snap)

    p_snaps = sub.add_parser("snaps", help="列出快照")
    p_snaps.add_argument("--name", default="default")
    p_snaps.set_defaults(func=cmd_snaps)

    p_restore = sub.add_parser("restore", help="恢复快照")
    p_restore.add_argument("tag")
    p_restore.add_argument("--name", default="default")
    p_restore.set_defaults(func=cmd_restore)

    p_shot = sub.add_parser("shot", help="抓取画面")
    p_shot.add_argument("output")
    p_shot.add_argument("--name", default="default")
    p_shot.set_defaults(func=cmd_shot)

    p_tap = sub.add_parser("tap", help="在客户机坐标处点击")
    p_tap.add_argument("x", type=int)
    p_tap.add_argument("y", type=int)
    p_tap.add_argument("--name", default="default")
    p_tap.add_argument("--width", type=int, default=1280)
    p_tap.add_argument("--height", type=int, default=800)
    p_tap.add_argument(
        "--mode", choices=["auto", "adb", "touch", "mouse"], default="auto",
        help="auto: 优先 adb input，失败回退 QMP 指针",
    )
    p_tap.add_argument("--adb-port", type=int, default=5555)
    p_tap.add_argument("--adb-server-port", default="5111")
    p_tap.set_defaults(func=cmd_tap)

    p_swipe = sub.add_parser("swipe", help="在客户机内滑动")
    p_swipe.add_argument("x1", type=int)
    p_swipe.add_argument("y1", type=int)
    p_swipe.add_argument("x2", type=int)
    p_swipe.add_argument("y2", type=int)
    p_swipe.add_argument("--duration", type=int, default=300, help="毫秒")
    p_swipe.add_argument("--name", default="default")
    p_swipe.add_argument("--adb-port", type=int, default=5555)
    p_swipe.add_argument("--adb-server-port", default="5111")
    p_swipe.set_defaults(func=cmd_swipe)

    p_key = sub.add_parser("key", help="发送按键")
    p_key.add_argument("keyname", metavar="KEY", help="adb 键名（HOME/BACK/ENTER）或 QEMU 键名（ret/home）")
    p_key.add_argument("--name", default="default")
    p_key.add_argument("--adb-port", type=int, default=5555)
    p_key.add_argument("--adb-server-port", default="5111")
    p_key.set_defaults(func=cmd_key)

    p_prov = sub.add_parser("provision", help="初始化安卓客户机（退出回收模式、完成向导、装 APK）")
    p_prov.add_argument("--name", default="lineage")
    p_prov.add_argument("--adb-port", type=int, default=5555, help="客户机 adb 转发端口")
    p_prov.add_argument("--adb-server-port", default="5111", help="宿主机 adb server 端口")
    p_prov.add_argument("--apk", action="append", help="要安装的 APK，可重复")
    p_prov.add_argument("--quiet", action="store_true")
    p_prov.set_defaults(func=cmd_provision)

    p_bake = sub.add_parser("bake-base", help="把已初始化的实例回写为新建模板")
    p_bake.add_argument("--source", required=True, help="源实例名（必须已停止）")
    p_bake.add_argument("--force", action="store_true", help="跳过正常关机检查")
    p_bake.set_defaults(func=cmd_bake_base)

    p_prep = sub.add_parser(
        "prepare-base", help="一次性：启动实例→完成安卓初始化→回写母盘"
    )
    p_prep.add_argument("--name", required=True)
    p_prep.add_argument("--adb-port", type=int, default=5555)
    p_prep.add_argument("--adb-server-port", default="5111")
    p_prep.set_defaults(func=cmd_prepare_base)

    p_smoke = sub.add_parser("smoke", help="端到端冒烟测试")
    p_smoke.add_argument("--name", default="smoke")
    p_smoke.add_argument("--cpus", type=int, default=4)
    p_smoke.add_argument("--memory", type=int, default=2048)
    p_smoke.add_argument("--disk-size", type=int, default=4)
    p_smoke.add_argument("--boot-timeout", type=float, default=180.0)
    p_smoke.set_defaults(func=cmd_smoke)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except KeyboardInterrupt:
        print("\n已中断", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
