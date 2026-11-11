"""VM instance lifecycle.

Design rule: this module never imports or links anything from QEMU. It builds
an argv, spawns the binary as a child process, and talks to it over QMP.
"""

from __future__ import annotations

import os
import re
import shutil
import signal
import subprocess
import time
from pathlib import Path

from .config import VMConfig
from .qmp import QMPClient, QMPError
from . import paths

QEMU_BIN = "qemu-system-aarch64"
QEMU_IMG = "qemu-img"
# Homebrew keg for the virgl-enabled build (startergo/qemu-virgl). The stock
# Homebrew QEMU has no virtio-gpu-gl support, so a virgl instance must run on
# this binary.
QEMU_VIRGL_DIR = "/opt/homebrew/opt/qemu-virgl/bin"


def android_cmdline(cfg: VMConfig) -> str:
    """Assemble the kernel cmdline for the direct-boot path.

    Static part: boot-assets/cmdline.txt (extracted from the image's
    vendor_boot cmdline + flattened bootconfig keys). Dynamic part: engine
    config — the MuMu model where boot switches belong to the launcher, not
    the disk. The two security-relevant switches only appear when the user
    has explicitly enabled them for this instance. xres/yres/dpi map to the
    GRUB-era official switches (virtio_gpu.force_resolution /
    androidboot.lcd_density) — the E10 finding that QEMU's own device
    xres/yres never reach the guest.
    """
    static_path = paths.IMAGES_DIR / "boot-assets" / "cmdline.txt"
    parts: list[str] = []
    if static_path.exists():
        # Ignore comment/blank lines — a '#' line inside -append broke the
        # qemu.cmd argument file and left the kernel without any cmdline.
        static = " ".join(
            ln.strip()
            for ln in static_path.read_text().splitlines()
            if ln.strip() and not ln.strip().startswith("#")
        )
        if static:
            parts.append(static)
    if cfg.insecure_adb:
        parts.append("androidboot.insecure_adb=1")
    if cfg.selinux_permissive:
        parts.append("androidboot.selinux=permissive")
    if getattr(cfg, "xres", None) and getattr(cfg, "yres", None):
        parts.append(f"virtio_gpu.force_resolution={cfg.xres}x{cfg.yres}")
    if getattr(cfg, "dpi", None):
        parts.append(f"androidboot.lcd_density={cfg.dpi}")
    parts.append("androidboot.console=hvc0 androidboot.seriallogging=hvc1 console=ttyAMA0")
    return " ".join(p for p in parts if p)


def qemu_binary(cfg: VMConfig | None = None) -> str:
    if cfg is not None and getattr(cfg, "gpu_backend", "virgl") == "virgl":
        candidate = os.path.join(QEMU_VIRGL_DIR, QEMU_BIN)
        if Path(candidate).exists():
            return candidate
        raise RuntimeError(
            f"gpu_backend=virgl 需要 qemu-virgl 版二进制，未找到 {candidate}。"
            "先执行: brew install startergo/qemu-virgl/qemu-virgl"
        )
    found = shutil.which(QEMU_BIN)
    if not found:
        raise RuntimeError(
            f"未找到 {QEMU_BIN}。先执行: brew install qemu"
        )
    return found


def qemu_img_binary() -> str:
    found = shutil.which(QEMU_IMG)
    if not found:
        raise RuntimeError(f"未找到 {QEMU_IMG}。先执行: brew install qemu")
    return found


class VM:
    def __init__(self, cfg: VMConfig, workdir: Path) -> None:
        self.cfg = cfg
        self.workdir = Path(workdir)
        self.qmp_sock = self.workdir / "qmp.sock"
        # A QMP chardev accepts a single client at a time. The UI holds its own
        # socket open for continuous frame capture, so control and display must
        # not share one.
        self.display_qmp_sock = self.workdir / "qmp-display.sock"
        # Input gets a third, dedicated socket. Pointer events have to leave the
        # UI in a couple of milliseconds, which rules out spawning a CLI process
        # per tap — and rules out sharing a socket that snapshot and status
        # commands connect to on their own schedule.
        self.input_qmp_sock = self.workdir / "qmp-input.sock"
        self.serial_log = self.workdir / "serial.log"
        self.qemu_log = self.workdir / "qemu.log"
        self.pid_file = self.workdir / "qemu.pid"
        self._proc: subprocess.Popen | None = None
        self.qmp: QMPClient | None = None
        self._input_qmp: QMPClient | None = None

    # -- argv --------------------------------------------------------------

    def build_args(self, paused: bool = False) -> list[str]:
        cfg = self.cfg
        machine = f"{cfg.machine},accel={cfg.accel}"
        args: list[str] = [
            qemu_binary(cfg),
            "-name", cfg.name,
            "-machine", machine,
            "-cpu", cfg.cpu,
            "-smp", str(cfg.cpus),
            "-m", str(cfg.memory_mb),
            "-qmp", f"unix:{self.qmp_sock},server=on,wait=off",
            "-qmp", f"unix:{self.display_qmp_sock},server=on,wait=off",
            "-qmp", f"unix:{self.input_qmp_sock},server=on,wait=off",
            "-serial", f"file:{self.serial_log}",
            "-monitor", "none",
            "-rtc", "base=utc",
        ]

        # virtio-gpu-gl-pci refuses to start on a GL-less display backend
        # ("The display backend does not have OpenGL support enabled"), and
        # -vnc is rejected as "incompatible with the GL context" (E10). macOS
        # has no egl-headless, so a virgl instance always renders through a
        # cocoa,gl=es window (ANGLE/Metal) and has no VNC/screendump-style
        # streaming path — the QEMU window is the display.
        if cfg.gpu and getattr(cfg, "gpu_backend", "virgl") == "virgl":
            args += ["-display", "cocoa,gl=es"]
            if getattr(cfg, "vnc_display", None) is not None:
                self.vnc_disabled_reason = (
                    "virgl 后端与 VNC 不兼容（QEMU 拒绝 GL 上下文共享），"
                    "显示走 QEMU cocoa 窗口"
                )
        else:
            args += ["-display", "none" if cfg.headless else "cocoa"]

        # virgl blobs need memory the guest can mmap directly. macOS has no
        # memfd backend, so host-visible buffers ride on a shared file (same
        # trick UTM uses). The file grows to the VM's memory size on first run.
        if getattr(cfg, "gpu_backend", "virgl") == "virgl" and cfg.gpu:
            memfile = self.workdir / "memfile"
            args[args.index("-machine") + 1] = machine + ",memory-backend=mem"
            args += [
                "-object",
                f"memory-backend-file,id=mem,size={cfg.memory_mb}M,"
                f"mem-path={memfile},share=on",
            ]

        # VNC is a *separate* display backend from -display. Both can be active
        # at once: -display none suppresses the local window while -vnc keeps
        # feeding framebuffer damage to the RFB client. Verified on QEMU 11.
        # `lossy` only affects Tight/JPEG; we negotiate ZRLE in the client.
        # Exception: virgl — QEMU rejects VNC next to a GL context (E10).
        vnc_ok = not (cfg.gpu and getattr(cfg, "gpu_backend", "virgl") == "virgl")
        if vnc_ok and getattr(cfg, "vnc_display", None) is not None:
            args += ["-vnc", f"127.0.0.1:{cfg.vnc_display},lossy=on"]

        # --- Boot path selection --------------------------------------------
        # Direct kernel boot (MuMu-style): the engine starts the extracted GKI
        # kernel via QEMU's built-in bootloader and owns the cmdline. No EDK2,
        # no GRUB — verified E12: ~25 s to boot_completed, adb direct, SELinux
        # per engine config. Fallback is the legacy UEFI/GRUB pflash path.
        boot_assets = paths.IMAGES_DIR / "boot-assets"
        direct = (
            cfg.direct_boot
            and (boot_assets / "kernel").exists()
            and (boot_assets / "initrd.img").exists()
        )
        if direct:
            args += [
                "-kernel", str(boot_assets / "kernel"),
                "-initrd", str(boot_assets / "initrd.img"),
                "-append", android_cmdline(cfg),
            ]
        else:
            if cfg.pflash_code:
                args += [
                    "-drive",
                    f"if=pflash,unit=0,file={cfg.pflash_code},file.locking=off,format=raw,readonly=on",
                ]
            if cfg.pflash_vars:
                vars_format = "qcow2" if str(cfg.pflash_vars).endswith(".qcow2") else "raw"
                args += [
                    "-drive",
                    f"if=pflash,unit=1,file={cfg.pflash_vars},format={vars_format}",
                ]

            if cfg.machine_firmware and not cfg.pflash_code:
                args += ["-bios", cfg.machine_firmware]

        # Start with the CPU halted. Combined with `loadvm` this skips the
        # guest's boot path entirely — which matters because a cold boot of this
        # Android image enters ADB trade-in mode and marks /metadata for a
        # factory reset on the following boot.
        if paused:
            args.append("-S")

        if cfg.kernel:
            args += ["-kernel", cfg.kernel]
            if cfg.initrd:
                args += ["-initrd", cfg.initrd]
            if cfg.append:
                args += ["-append", cfg.append]

        if cfg.disks:
            for index, entry in enumerate(cfg.disks):
                drive_id = entry.get("id") or f"vd{chr(ord('a') + index)}"
                fmt = entry.get("format", "qcow2")
                # file.locking=off：macOS 上 file-posix 的 flock 按 open file
                # description 计，QEMU attach 块设备时 reopen 同一文件会与
                # 自己刚加的锁冲突，启动即 "Failed to get write lock"。
                # 双开保护由 pid 文件 + 管理器负责，这里不需要文件锁。
                args += [
                    "-drive",
                    f"file={entry['file']},if=none,id={drive_id},format={fmt},"
                    "discard=unmap,detect-zeroes=unmap,file.locking=off",
                ]
                software_boot = (
                    f",bootindex={entry['bootindex']}" if "bootindex" in entry else ""
                )
                args += ["-device", f"virtio-blk-pci,drive={drive_id}{software_boot}"]
        elif cfg.disk:
            args += [
                "-drive", f"file={cfg.disk},if=none,id=hd0,format=qcow2,cache=writeback",
                "-device", "virtio-blk-pci,drive=hd0",
            ]

        if cfg.cdrom:
            cdrom = Path(cfg.cdrom)
            fmt = "qcow2" if cdrom.suffix in (".qcow2",) else "raw"
            args += [
                "-drive", f"file={cdrom},if=none,id=cd0,format={fmt},media=cdrom",
                "-device", "virtio-scsi-pci,id=scsi0",
                "-device", "scsi-cd,drive=cd0",
            ]

        netdev = "user,model=virtio-net-pci"
        forwards = list(cfg.hostfwd)
        if cfg.ssh_port:
            forwards.append(f"tcp:127.0.0.1:{cfg.ssh_port}-:22")
        if forwards:
            netdev += ",hostfwd=" + ",hostfwd=".join(forwards)
        args += ["-nic", netdev]

        # Entropy source. Android's keystore/keymint init blocks without it.
        args += ["-device", "virtio-rng-pci"]

        if cfg.gpu:
            if getattr(cfg, "gpu_backend", "virgl") == "virgl":
                # blob=on + hostmem: minigbm's host-visible allocation path
                # (E4, the switch that turned GL on). edid=off collapses the
                # connector to a single display mode; with EDID's 20+ modes
                # SurfaceFlinger's frame-rate voting hits a LOG(FATAL) and
                # loops forever (E6 -> E7).
                args += ["-device", "virtio-gpu-gl-pci,blob=on,hostmem=1G,edid=off"]
            else:
                # xres/yres set the initial scanout size. Guests that honour
                # EDID/surface probing (Alpine, most Linux) pick it up; the
                # LineageOS image currently settles at its own mode (E10),
                # but passing it is harmless and keeps create/clone honest.
                geometry = ""
                if getattr(cfg, "xres", None) and getattr(cfg, "yres", None):
                    geometry = f",xres={cfg.xres},yres={cfg.yres}"
                args += ["-device", f"virtio-gpu-pci{geometry}"]
        # Absolute pointer for ordinary UI, plus a real touchscreen for surfaces
        # that ignore mouse buttons entirely (Unity games, some system dialogs).
        args += [
            "-device", "qemu-xhci",
            "-device", "usb-kbd",
            "-device", "usb-tablet",
        ]
        if cfg.touch:
            args += ["-device", "virtio-multitouch-pci"]

        args += cfg.extra_args
        return args

    # -- disk --------------------------------------------------------------

    @staticmethod
    def create_disk(path: Path, size_gb: int) -> Path:
        path.parent.mkdir(parents=True, exist_ok=True)
        if not path.exists():
            subprocess.run(
                [qemu_img_binary(), "create", "-f", "qcow2", str(path), f"{size_gb}G"],
                check=True,
                capture_output=True,
            )
        return path

    @staticmethod
    def to_qcow2(source: Path, target: Path) -> Path:
        """Convert a raw image (e.g. an ISO) to qcow2.

        Internal VM snapshots require every attached block device to support
        snapshots; raw images do not. Converting the install media is what makes
        full-state savevm work with a CD-ROM attached.
        """
        if not target.exists():
            subprocess.run(
                [qemu_img_binary(), "convert", "-O", "qcow2", str(source), str(target)],
                check=True,
                capture_output=True,
            )
        return target

    # -- lifecycle ---------------------------------------------------------

    def plan(self, paused: bool = False) -> list[str]:
        """Prepare an instance for someone else to run QEMU.

        The GUI's player embeds QEMU in its own process, so it cannot call
        start(): that would spawn a *second* QEMU next to the embedded one.
        Everything start() does before the fork happens here instead — clear
        stale pids/sockets, build the argv, persist qemu.cmd — and the caller
        takes over from the exec.
        """
        self.workdir.mkdir(parents=True, exist_ok=True)
        self._clear_stale_state()
        self._remove_stale_socket()

        args = self.build_args(paused=paused)
        (self.workdir / "qemu.cmd").write_text("\n".join(args) + "\n")
        return args

    def start(
        self, wait_running: bool = True, timeout: float = 25.0, paused: bool = False
    ) -> int:
        args = self.plan(paused=paused)

        log = open(self.qemu_log, "ab")
        try:
            self._proc = subprocess.Popen(
                args,
                stdin=subprocess.DEVNULL,
                stdout=log,
                stderr=log,
                start_new_session=True,
            )
        finally:
            log.close()

        self.pid_file.write_text(str(self._proc.pid))

        self.qmp = QMPClient(self.qmp_sock)
        self.qmp.connect(wait=timeout)
        if wait_running:
            self.wait_status("running", timeout=15.0)
        return self._proc.pid

    def attach(self) -> QMPClient:
        """Reconnect to an already-running instance.

        The timeout is generous on purpose: `savevm` on a multi-gigabyte guest
        can take well over ten seconds and would otherwise trip the read timeout.
        """
        if self.qmp is None:
            self.qmp = QMPClient(self.qmp_sock, timeout=120.0)
            self.qmp.connect(wait=10.0)
        return self.qmp

    def input_attach(self) -> QMPClient:
        """Connect to the dedicated input socket.

        Kept off the control socket so a tap never has to wait behind a snapshot
        or a status poll, and short-timeout so a wedged guest fails fast instead
        of freezing the caller.
        """
        if self._input_qmp is None:
            client = QMPClient(self.input_qmp_sock, timeout=5.0)
            client.connect(wait=3.0)
            self._input_qmp = client
        return self._input_qmp

    def _adb_serial(self) -> str | None:
        """Host-side adb serial for this instance, from its hostfwd rule.

        Rule shape is `tcp:127.0.0.1:<host>-:<guest>`; the host port is
        parts[2] with a trailing dash. Reading parts[3] here would return the
        guest port and connect to the wrong machine.
        """
        for rule in self.cfg.hostfwd or []:
            parts = rule.split(":")
            if len(parts) < 4:
                continue
            if parts[3].split("-", 1)[0] != "5555":
                continue
            host = parts[2].split("-", 1)[0]
            if host.isdigit():
                return f"127.0.0.1:{host}"
        return None

    def adb_poweroff(self, timeout: float = 90.0) -> bool:
        """Ask Android to shut itself down and wait for `reboot: Power down`.

        QEMU's `system_powerdown` is an ACPI event, and this machine has no
        gpio-keys node for Android to route it to, so it is silently ignored.
        `adb shell reboot -p` is the real path: it stops services, syncs, unmounts
        and prints `reboot: Power down`. That marker is what `bake-base` checks —
        stopping the process any other way leaves a vfat /vendor/firmware_mnt
        half-written, and every clone of that image then fails to mount it and
        reboots forever (E18).
        """
        serial = self._adb_serial()
        if serial is None or not shutil.which("adb"):
            return False
        env = dict(os.environ, ANDROID_ADB_SERVER_PORT=os.environ.get("ANDROID_ADB_SERVER_PORT", "5111"))
        try:
            subprocess.run(["adb", "connect", serial], capture_output=True, timeout=10, env=env)
            probe = subprocess.run(
                ["adb", "-s", serial, "shell", "getprop", "sys.boot_completed"],
                capture_output=True, text=True, timeout=15, env=env,
            )
            if probe.stdout.strip() != "1":
                return False
            subprocess.run(
                ["adb", "-s", serial, "shell", "sync; reboot -p"],
                capture_output=True, timeout=30, env=env,
            )
        except (subprocess.SubprocessError, OSError):
            return False

        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if not self._pid_alive(self.read_pid() or -1):
                return True
            time.sleep(1.0)
        return False

    def stop(self, graceful: bool = False, timeout: float = 20.0) -> None:
        pid = self.read_pid()
        if pid is None:
            self._cleanup_socket()
            return

        if graceful and self.adb_poweroff():
            self._cleanup_socket()
            return

        try:
            self.attach()
        except QMPError:
            self.qmp = None

        if self.qmp is not None:
            if graceful:
                try:
                    self.qmp.execute("system_powerdown")
                    self._wait_exit(pid, timeout)
                    self._cleanup_socket()
                    return
                except (QMPError, TimeoutError):
                    pass
            try:
                self.qmp.execute("quit")
            except QMPError:
                pass

        self._wait_exit(pid, timeout)
        if self._pid_alive(pid):
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            self._wait_exit(pid, 5.0)
        if self._pid_alive(pid):
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        self._cleanup_socket()

    # -- state -------------------------------------------------------------

    def query_status(self) -> dict:
        self.attach()
        return self.qmp.execute("query-status") or {}

    def wait_status(self, target: str, timeout: float = 10.0) -> str:
        deadline = time.monotonic() + timeout
        current = "unknown"
        while time.monotonic() < deadline:
            current = self.query_status().get("status", "unknown")
            if current == target:
                return current
            time.sleep(0.1)
        raise QMPError(f"等待状态 {target} 超时，当前为 {current}")

    def is_running(self) -> bool:
        # If we own the child handle, poll() is authoritative *and* reaps the
        # process. Only fall back to the pid file for a fresh CLI invocation,
        # where the child has already been reparented and therefore cannot be a
        # zombie.
        if self._proc is not None:
            return self._proc.poll() is None
        pid = self.read_pid()
        if pid is None or not _pid_exists(pid):
            return False
        # A stale pid file plus pid reuse makes a dead instance look alive.
        # Confirm the pid still belongs to a QEMU process — or to our embedded
        # player, which carries QEMU inside its own address space and is the
        # only thing holding this instance when the GUI launches it.
        path = _process_path(pid)
        return path is None or path.endswith(QEMU_BIN) or "andropod-player" in path

    # -- snapshots ---------------------------------------------------------

    def _disk_node(self) -> str:
        if self.cfg.disks:
            first = self.cfg.disks[0].get("id") or "vda"
            return first
        if not self.cfg.disk:
            raise RuntimeError("该实例没有磁盘，无法做快照")
        return "hd0"

    def savevm(self, tag: str) -> list[str]:
        self._disk_node()  # fail early with a clear message if no disk
        # savevm goes through the human monitor, which splits on whitespace.
        # A tag with spaces silently truncates, so refuse it up front.
        if not tag or any(ch.isspace() for ch in tag):
            raise ValueError(f"快照标签不能包含空白字符: {tag!r}")
        self.attach()
        # HMP reports failures as text, not as a QMP error. Without this check
        # `savevm` "succeeds" while writing nothing — which is exactly how the
        # disk-only snapshots on this image went unnoticed.
        result = self.qmp.hmp(f"savevm {tag}")
        if _hmp_failed(result):
            raise RuntimeError(result.strip())
        return self.snapshots()

    def loadvm(self, tag: str) -> None:
        self.attach()
        result = self.qmp.hmp(f"loadvm {tag}")
        if _hmp_failed(result):
            raise RuntimeError(result.strip())

    def resume(self) -> None:
        self.attach()
        try:
            self.qmp.execute("cont")
        except QMPError:
            pass  # already running

    def delvm(self, tag: str) -> None:
        self.attach()
        self.qmp.hmp(f"delvm {tag}")

    def snapshots(self) -> list[str]:
        """List internal snapshots.

        QEMU 11 removed the `query-snapshots` QMP command, so this goes through
        the HMP `info snapshots` table and parses it by column offset — tag names
        may contain spaces, so splitting on whitespace is not safe.
        """
        self.attach()
        return _parse_info_snapshots(self.qmp.hmp("info snapshots"))

    def disk_snapshots(self) -> list[str]:
        """Snapshot tags read straight off the qcow2, without starting QEMU.

        The GUI has to decide *before* booting whether to restore a snapshot
        (that decision selects -S and changes the boot path), and it must not
        start a throwaway QEMU just to ask. qemu-img reads the same snapshot
        table from the image file.
        """
        if self.cfg.disks:
            target = Path(self.cfg.disks[0]["file"])
        elif self.cfg.disk:
            target = Path(self.cfg.disk)
        else:
            return []
        if not target.exists():
            return []

        result = subprocess.run(
            [qemu_img_binary(), "snapshot", "-l", str(target)],
            capture_output=True, text=True,
        )
        if result.returncode != 0:
            return []

        tags: list[str] = []
        for line in result.stdout.splitlines():
            fields = line.split()
            if len(fields) >= 2 and fields[0].isdigit():
                tags.append(fields[1])
        return tags

    # -- capture -----------------------------------------------------------

    def touch(self, x: int, y: int, width: int = 1280, height: int = 800) -> None:
        """Tap through the virtio touchscreen.

        QMP's mtt event carries one absolute axis per event, so a single tap is
        a short sequence: finger down, move to the second axis, lift.
        """
        self.attach()
        abs_x = max(0, min(32767, int(x / width * 32767)))
        abs_y = max(0, min(32767, int(y / height * 32767)))
        sequence = (
            ("begin", "x", abs_x),
            ("update", "y", abs_y),
            ("end", "x", abs_x),
        )
        for phase, axis, value in sequence:
            self.qmp.execute(
                "input-send-event",
                {
                    "events": [
                        {
                            "type": "mtt",
                            "data": {
                                "type": phase,
                                "slot": 0,
                                "tracking-id": 0,
                                "axis": axis,
                                "value": value,
                            },
                        }
                    ]
                },
            )
            time.sleep(0.02)

    def has_touch(self) -> bool:
        return bool(self.cfg.touch) if hasattr(self.cfg, "touch") else False

    def screendump(self, path: Path) -> Path:
        self.attach()
        path.parent.mkdir(parents=True, exist_ok=True)
        arguments: dict[str, str] = {"filename": str(path)}
        if path.suffix.lower() == ".png":
            arguments["format"] = "png"
        self.qmp.execute("screendump", arguments)
        return path

    # -- serial console ----------------------------------------------------

    def serial_text(self) -> str:
        if not self.serial_log.exists():
            return ""
        return self.serial_log.read_text(errors="replace")

    def wait_for_serial(self, pattern: str, timeout: float = 120.0) -> str:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            text = self.serial_text()
            if pattern in text:
                return text
            if not self.is_running():
                raise TimeoutError(
                    f"VM 已退出，串口日志中未出现 {pattern!r}。查看 {self.qemu_log}"
                )
            time.sleep(0.2)
        raise TimeoutError(f"等待串口输出 {pattern!r} 超时（{timeout}s）")

    # -- pid plumbing ------------------------------------------------------

    def read_pid(self) -> int | None:
        if not self.pid_file.exists():
            return None
        try:
            return int(self.pid_file.read_text().strip())
        except (ValueError, OSError):
            return None

    @staticmethod
    def _pid_alive(pid: int) -> bool:
        return _pid_exists(pid)

    def _wait_exit(self, pid: int | None, timeout: float) -> None:
        if pid is None:
            return
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self._proc is not None and self._proc.pid == pid:
                if self._proc.poll() is not None:
                    return
            elif not _pid_exists(pid):
                return
            time.sleep(0.1)
        raise TimeoutError(f"进程 {pid} 在 {timeout}s 内没有退出")

    def _clear_stale_state(self) -> None:
        """A crashed or killed run leaves a pid file behind. Without this, the
        next start refuses to launch because the instance looks busy."""
        pid = self.read_pid()
        if pid is not None and not _pid_exists(pid):
            try:
                self.pid_file.unlink()
            except OSError:
                pass

    def _remove_stale_socket(self) -> None:
        for sock in (self.qmp_sock, self.display_qmp_sock, self.input_qmp_sock):
            if sock.exists():
                try:
                    sock.unlink()
                except OSError:
                    pass

    def _cleanup_socket(self) -> None:
        self._remove_stale_socket()
        if self.qmp is not None:
            self.qmp.close()
            self.qmp = None
        if self.pid_file.exists():
            try:
                self.pid_file.unlink()
            except OSError:
                pass


def _pid_exists(pid: int) -> bool:
    """Liveness check that does not require spawning external tools.

    `ps` is unavailable in restricted environments, and `kill(pid, 0)` is the
    portable syscall-level answer. It cannot tell a zombie from a live process,
    which is why callers holding a Popen handle must use poll() instead.
    """
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return False
    return True


def _process_path(pid: int) -> str | None:
    """Executable path of a pid, via libproc.

    Used to tell a live QEMU from a recycled pid left behind by a crash: `ps` is
    unavailable in restricted environments, but libproc always works on macOS.
    """
    try:
        import ctypes
        import ctypes.util

        library = ctypes.CDLL(ctypes.util.find_library("proc") or "/usr/lib/libproc.dylib")
        buffer = ctypes.create_string_buffer(4096)
        if library.proc_pidpath(pid, buffer, 4096) <= 0:
            return None
        return buffer.value.decode("utf-8", "replace")
    except Exception:  # noqa: BLE001 - never let diagnostics break liveness checks
        return None


def _hmp_failed(text: str) -> bool:
    """HMP commands report failures as prose in the reply.

    `human-monitor-command` itself always succeeds at the QMP level, so a
    failing savevm/loadvm looks like a normal empty answer. QEMU prefixes
    these with "Error: " (e.g. "Error: virgl is not yet migratable"), so a
    case-insensitive search is enough and keeps us from missing a silent no-op.
    """
    return "error" in text.lower()


def _parse_info_snapshots(text: str) -> list[str]:
    """Parse the HMP `info snapshots` table.

    Layout (QEMU 11):
        ID      TAG               VM_SIZE                DATE        VM_CLOCK     ICOUNT
        --      configured       3.82 GiB 2026-11-09 14:04:18  0000:08:08.302         --

    Column widths are not stable across versions, so we anchor on structure:
    id, tag, size, then a date. The tag is matched lazily so tags containing
    spaces still work.
    """
    tags: list[str] = []
    for line in text.splitlines():
        match = _SNAPSHOT_ROW.match(line)
        if match:
            tag = match.group("tag").strip()
            if tag:
                tags.append(tag)
    return tags


_SNAPSHOT_ROW = re.compile(
    r"^\s*\S+\s+(?P<tag>.+?)\s+\d+(?:\.\d+)?\s+[KMGTP]?i?B\s+\d{4}-\d{2}-\d{2}"
)
