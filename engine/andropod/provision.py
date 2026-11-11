"""First-boot provisioning for the Android guest.

Why this exists: on a **user** build, the DeviceDiagnostics service enables ADB
trade-in mode while the setup wizard is unfinished (no wifi, not provisioned,
`ro.debuggable=0`). adbd then lowers itself into the `adbd_tradeinmode` SELinux
domain, which allows exactly one shell command: `shell tradeinmode`. Every other
service — including `shell`, `sync`, `logcat` — is closed by design.

So a fresh boot cannot install anything until we walk the device out of that
state. That is what this module does, and it is a required step of every cold
boot, not an optional convenience.

Note the side effect: `tradeinmode evaluate` sets `persist.adb.tradeinmode=2`
and drops a wipe marker in /metadata. The next *cold boot* factory-resets the
device. This is why the product boots from a `savevm` snapshot instead of
restarting the guest.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import time
from pathlib import Path

DEFAULT_ADB_SERVER_PORT = "5111"
SETUP_WIZARD_PACKAGE = "org.lineageos.setupwizard"


class ProvisionError(RuntimeError):
    pass


def _adb(binary: str, args: list[str], server_port: str, timeout: float = 60) -> tuple[int, str]:
    environment = dict(os.environ)
    environment["ANDROID_ADB_SERVER_PORT"] = server_port
    try:
        result = subprocess.run(
            [binary, *args],
            capture_output=True,
            text=True,
            timeout=timeout,
            env=environment,
        )
    except subprocess.TimeoutExpired:
        return 124, "adb 超时"
    return result.returncode, (result.stdout or "") + (result.stderr or "")


def _require_adb() -> str:
    binary = shutil.which("adb")
    if not binary:
        raise ProvisionError("找不到 adb，先执行: brew install android-platform-tools")
    return binary


def shell(binary: str, serial: str, command: str, server_port: str, timeout: float = 120) -> tuple[int, str]:
    return _adb(binary, ["-s", serial, "shell", command], server_port, timeout)


def connect(binary: str, serial: str, server_port: str) -> None:
    _adb(binary, ["connect", serial], server_port, 20)


def wait_for_device(binary: str, serial: str, server_port: str, timeout: float = 240) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        code, output = _adb(binary, ["-s", serial, "get-state"], server_port, 20)
        if code == 0 and "device" in output:
            return
        connect(binary, serial, server_port)
        time.sleep(2)
    raise ProvisionError(f"等待设备 {serial} 超时")


def wait_boot_completed(
    binary: str, serial: str, server_port: str, timeout: float = 300
) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        code, output = shell(binary, serial, "getprop sys.boot_completed", server_port, 20)
        if code == 0 and output.strip() == "1":
            return
        time.sleep(3)
    raise ProvisionError("等待 sys.boot_completed 超时")


def in_tradein_mode(binary: str, serial: str, server_port: str) -> bool:
    code, output = shell(binary, serial, "tradeinmode getstatus", server_port, 30)
    return code == 0 and "battery" in output.lower()


def exit_tradein_mode(binary: str, serial: str, server_port: str) -> bool:
    """Leave trade-in mode. Returns True if it was active."""
    if not in_tradein_mode(binary, serial, server_port):
        return False
    shell(binary, serial, "tradeinmode evaluate", server_port, 30)
    # adbd restarts and drops the connection.
    time.sleep(8)
    _adb(binary, ["disconnect", serial], server_port, 20)
    connect(binary, serial, server_port)
    wait_for_device(binary, serial, server_port, timeout=120)
    return True


def provision(
    serial: str,
    server_port: str = DEFAULT_ADB_SERVER_PORT,
    apks: list[Path] | None = None,
    verbose: bool = True,
) -> dict:
    """Bring a freshly booted guest to a usable desktop with working ADB."""
    binary = _require_adb()
    report: dict[str, object] = {}

    def log(message: str) -> None:
        if verbose:
            print(message)

    log(f"连接 {serial}")
    connect(binary, serial, server_port)
    wait_for_device(binary, serial, server_port)

    # Trade-in mode can engage at two different moments: early (before the boot
    # completes) and again once DeviceDiagnostics runs at BOOT_COMPLETED. And in
    # trade-in mode `adb shell` refuses everything except `tradeinmode`, so we
    # must clear it *before* we can even ask for sys.boot_completed.
    was_tradein = exit_tradein_mode(binary, serial, server_port)

    log("等待系统启动完成")
    wait_boot_completed(binary, serial, server_port)

    log("复查 ADB 回收模式")
    if exit_tradein_mode(binary, serial, server_port):
        was_tradein = True
        wait_boot_completed(binary, serial, server_port, timeout=120)

    report["tradein"] = was_tradein
    log("  之前处于回收模式，已退出" if was_tradein else "  不在回收模式")

    log("标记设置向导完成")
    for command in (
        "settings put secure user_setup_complete 1",
        "settings put global device_provisioned 1",
        f"pm disable-user --user 0 {SETUP_WIZARD_PACKAGE}",
        # MuMu 的客机不带原生状态栏/导航栏：应用内容占满整个画面。policy_control
        # 在新版 Android 上可能已被移除——失败无害（settings 返回错误但进程为 0），
        # 留在列表里让所有支持的版本都拿到一致的观感。
        "settings put global policy_control immersive.full=*",
    ):
        shell(binary, serial, command, server_port, 40)

    log("进入桌面")
    shell(
        binary,
        serial,
        "am start -a android.intent.action.MAIN -c android.intent.category.HOME",
        server_port,
        40,
    )

    installed: list[str] = []
    for apk in apks or []:
        log(f"安装 {apk.name}")
        code, output = _adb(binary, ["-s", serial, "install", "-r", str(apk)], server_port, 600)
        success = code == 0 and "Success" in output
        log(f"  {'成功' if success else '失败: ' + output.strip()[:200]}")
        if success:
            installed.append(apk.name)

    # 模拟器桌面（MuMu 式产品层）：预装后接管 HOME 角色。由产品在初始化时
    # 执行，不是运行中的设备上随手改——这是出厂配置的一部分。
    home_apk = Path(__file__).resolve().parents[2] / "runtime" / "images" / "extra-apks" / "andropod-home.apk"
    if home_apk.exists() and "com.andropod.home" not in installed:
        log("安装模拟器桌面")
        code, output = _adb(binary, ["-s", serial, "install", "-r", str(home_apk)], server_port, 600)
        if code == 0 and "Success" in output:
            installed.append("andropod-home.apk")
            shell(binary, serial, "cmd role add-role-holder android.app.role.HOME com.andropod.home", server_port, 40)
            log("  已安装并设为默认桌面")
        else:
            log(f"  失败: {output.strip()[:200]}")
    report["installed"] = installed

    code, output = shell(binary, serial, "getprop ro.build.version.release", server_port, 20)
    report["android"] = output.strip()
    return report
