# ADB 阻塞问题的定位与解决

上一轮记录的「`adb devices` 显示 device，但所有服务返回 `error: closed`」不是环境问题，也不是镜像缺陷，而是 **Android 的一项安全设计**。

## 证据链

1. **原始协议抓包**（`scripts/adb_probe.py`）
   设备接受 CNXN 握手并返回完整 banner，但收到 `OPEN shell:` 后立刻回 `CLSE`，且 `arg0=0` —— 连 remote id 都没分配。结论：**adbd 主动拒绝，不是传输问题**。

2. **逐项探测**
   `shell` / `shell,v2` / `log` / `reboot` / `sync` 全部 `CLSE`。注意 `host:version` 也失败是正常的——`host:` 是 host 侧服务，adbd 本来就不处理。

3. **内核日志里的 SELinux 上下文**
   ```
   scontext=u:r:adbd_tradeinmode:s0
   ```
   adbd 不在正常的 `adbd` 域，而在 `adbd_tradeinmode` 域。

## 这是什么

Android 13 起引入的 **ADB 回收模式（Trade-In Mode, TIM）**。触发条件（AOSP 文档原文）：

1. ADB 被关闭
2. `ro.debuggable` = 0（user 构建）
3. `USER_SETUP_COMPLETE` = 0
4. `DEVICE_PROVISIONED` = 0
5. 没有活动的 Wi-Fi 连接

**五条我们全中**：这是 LineageOS 的 user 构建，而设备停在设置向导的第一屏。

一旦条件满足，`DeviceDiagnostics` 把 `persist.adb.tradeinmode` 置 1，adbd 重启时通过 `setcon()` 降权到 `adbd_tradeinmode`，该域**只允许一条命令**：`adb shell tradeinmode`。这是为了让人工回收商能在不完成设置向导的前提下跑自动化检测，同时不给出完整 ADB 权限。

所以「所有服务被拒」是**正确行为**。

## 解法

```bash
adb shell tradeinmode evaluate
```

`evaluate` 把 `persist.adb.tradeinmode` 置 2 并重启 adbd，此时 adbd 以正常域运行、且**关闭授权校验**，完整 ADB 可用。

验证：

```
$ adb shell "echo ADB_OK; getprop ro.build.version.release; id"
ADB_OK
16
uid=2000(shell) ... context=u:r:shell:s0
```

## 代价：下次冷启动会恢复出厂

`evaluate` 会在 `/metadata/tradeinmode/wipe` 写一个标记，**首次阶段 init 看到它就重启进 recovery 执行擦除**。实测确实发生了：

```
reboot: Restarting system with command 'recovery'
```

擦除完成后系统重启，回到设置向导，TIM 再次生效。

`/metadata` 是 root 0700，user 构建下 `adb shell` 删不掉这个标记（`Permission denied`）。

### 这直接决定了产品架构

**必须靠快照启动，不能靠冷启动。**

- 冷启动 → 进向导 → TIM → 需要 `evaluate` → 打擦除标记 → 下次又擦
- 快照启动 → 不经过 init → 不检查擦除标记 → 状态完整保留

具体实现是三步，缺一不可：

```
qemu ... -S          # 1. CPU 停在复位状态，客户机一条指令都没执行
loadvm clean         # 2. 恢复内存 + 设备状态
cont                 # 3. 放行
```

用 `-S` 是关键：如果先让它引导再去 `loadvm`，init 已经跑过、已经检查过擦除标记了。

命令：

```bash
./bin/andropod boot --name lineage --snapshot clean
# 已从快照 'clean' 启动 lineage  3.61s（未经过客户机引导）
```

实测 3.61 秒，对比冷启动约 2 分钟。恢复后 `getprop sys.boot_completed` = 1、`ro.build.version.release` = 16、第三方包（Clash of Clans）仍在。

GUI 的「启动」按钮已经改成优先走这条路：有 `clean` 快照就 `boot`，没有才回退到冷启动并提示先做「初始化」。

## 同时修掉的两个坑

### 1. pflash 变量区必须是 qcow2 才能做快照

```
Error: Device 'pflash1' is writable but does not support snapshots
```

EFI 变量区原本是 raw，而 raw 不支持内部快照。改成 `qemu-img create -f qcow2 efi_vars.qcow2 64M` 即可（实测 pflash 接受 qcow2 后端）。

### 2. 快照标签不能含空格

`savevm` 走的是 HMP，按空白分词。`savevm before game` 会被截断成 `savevm before`。已在 `VM.savevm()` 里提前校验并给出明确报错。

## 一键初始化产品化

`andropod provision` 把整套流程固化成一条命令：

```bash
./bin/andropod provision --name lineage --apk /path/to/app.apk
```

它做这些事，顺序有讲究：

1. 连接并等待设备
2. **先尝试退出 TIM**（不能等 `boot_completed`，因为 TIM 下 `shell getprop` 也会被拒）
3. 等 `sys.boot_completed`
4. **再复查一次 TIM** —— DeviceDiagnostics 在 `BOOT_COMPLETED` 时可能又把它打开
5. 写 `user_setup_complete` / `device_provisioned`
6. 禁用 `org.lineageos.setupwizard`
7. 拉起 HOME
8. 逐个安装 APK

实测输出：

```
连接 127.0.0.1:5555
等待系统启动完成
复查 ADB 回收模式
  之前处于回收模式，已退出
标记设置向导完成
进入桌面
安装 10040714_..._clashofclans.apk
  成功
{ "tradein": true, "installed": [...], "android": "16" }
```

## 实测数据

| 项目 | 数值 |
|---|---|
| 冷启动到设置向导 | ~2 min |
| TIM 退出到完整 ADB | ~8 s（adbd 重启） |
| 911 MB APK 安装（流式） | **4 s** |
| savevm（4 GB RAM） | 2.78 s |
| loadvm | 2.78 s |

## 仍然存在的问题

**部分应用弹窗的按钮点不动，但不是输入通道的问题。**

早先怀疑「Unity / 系统弹窗只收 touch 不收 mouse」，后续实验推翻了：`adb shell input swipe` 能滚动协议正文，滚动到底后 `input tap` 能正常点「同意」。

真实原因是**按钮状态门控**——协议正文没滚到底时按钮是禁用的，视觉上却是绿的。这类现象极易误判成注入失效。

因此输入层已改为：**adb `input` 优先，QMP 指针兜底**（`engine/andropod/input.py`）。`virtio-multitouch-pci` 仍挂在虚拟机上，但 QMP `mtt` 事件序列还没调通（只产生 `ABS_MT_TRACKING_ID`，位置未下发），暂不作主路径。
