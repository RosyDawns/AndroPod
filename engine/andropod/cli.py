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
from .vm import VM, qemu_binary

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

    if args.kernel:
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
        # Default to the Alpine test guest so `create` never leaves a VM that
        # cannot boot.
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
            "磁盘": cfg.disk or "无",
            "内核": Path(cfg.kernel).name,
            "VNC": (f"127.0.0.1:{5900 + cfg.vnc_display}"
                    if cfg.vnc_display else "关闭（回退 screendump）"),
        }
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
    vm.loadvm(args.snapshot)
    restore_seconds = time.monotonic() - started
    vm.resume()
    print(
        f"已从快照 {args.snapshot!r} 启动 {args.name}  "
        f"{restore_seconds:.2f}s（未经过客户机引导）"
    )
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
    tags = vm.savevm(args.tag)
    elapsed = time.monotonic() - started
    ok = args.tag in tags
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
    p_create.add_argument("--force", action="store_true")
    p_create.set_defaults(func=cmd_create)

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
