# LineageOS 接入实测（阶段 1A）

目标：让真正的 Android 在原版 QEMU + HVF 上跑到可用状态。

结论：**跑起来了。** 系统启动、渲染、触控都通了；ADB 有阻塞，见"未解决"。

## 用到的镜像

```
UTM-VM-lineage-23.2-20261019-jqssun-virtio_arm64only.zip
sha256 = 171c0d215899d68f070fd45aea05ddb25737cf4ff16a25468e7cafbc65f4d8c9  ✓ 与 release 页一致
大小   = 1.0 GB
```

来自 `github.com/jqssun/android-lineage-qemu` 的 v2026.10.18 发布。LineageOS 23.2（Android 16）。

## 导入做了什么

`./bin/andropod import-utm --zip ... --name lineage`

1. 解压出 `LineageOS_on_arm64.utm/Data/`
2. 为 `vda.qcow2` / `vdb.qcow2` 各建一个 **qcow2 overlay**（backing file 指向原盘）——基础盘只存一份，多开几乎不占额外空间
3. 生成 **64 MiB** 的 `efi_vars.fd`

### 踩到的坑：pflash 变量区必须精确 64 MiB

UTM 包里带的 `efi_vars.fd` 只有 327 KB，是给 UTM 自带固件用的。Homebrew 的 EDK2 要求 pflash 单元正好 64 MiB，否则 QEMU 直接拒绝启动：

```
qemu-system-aarch64: cfi.pflash01 device '/machine/virt.flash1'
requires 67108864 bytes, pflash1 block backend provides 334848 bytes
```

解法：不用它，直接建一个 64 MiB 全零文件。EDK2 检测到没有合法头部会自行初始化。

## 启动参数

```
-machine virt,accel=hvf -cpu host -smp 4 -m 4096
-drive if=pflash,unit=0,file=edk2-aarch64-code.fd,readonly=on,format=raw
-drive if=pflash,unit=1,file=efi_vars.fd,format=raw
-device virtio-blk-pci,drive=vda,bootindex=0
-device virtio-blk-pci,drive=vdb,bootindex=1
-device virtio-gpu-pci
-device virtio-rng-pci
-device qemu-xhci -device usb-kbd -device usb-tablet
-nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:5555-:5555,hostfwd=tcp:127.0.0.1:5554-:5554
```

`virtio-rng-pci` 不是可选项：没有熵源，Android 的 keystore/keymint 初始化会卡住。

## 实测结果

| 项目 | 结果 |
|---|---|
| QMP 握手 | 0.13 s |
| 从进程启动到出现 LineageOS 开机动画 | 约 30 s |
| 到设置向导（Welcome 页） | 约 2 min（首次启动） |
| 帧缓冲分辨率 | 1280 × 800 |
| 抓帧（PNG） | 3–8 KB/帧，25–35 ms |
| 触控注入 | 可用，能连续推进 5 个向导页面 |
| 客户机识别 | 镜像正确识别为 "QEMU Virtual Machine"，报告 15.97 GB 可用空间 |

画面确认过：开机动画 → Welcome → Language → Date & time → Backup 来源 → Location services → Protect your phone，都有截图存档在 `runtime/instances/lineage/`。

## 踩到的坑：多个指针设备会打乱绝对坐标

最初同时挂了 `usb-tablet`（绝对）和 `usb-mouse`（相对）。结果是 `input-send-event` 送出的绝对坐标被当成**相对位移**处理，光标落在完全不相干的位置。

去掉 `usb-mouse`、只留 `usb-tablet` 之后，坐标立刻准确，向导开始正常响应。

规则记下来：**一个客户机只挂一个指针设备**。

## 未解决

### 1. ADB 服务打不开 —— 已解决

根因是 Android 的 **ADB 回收模式**（adbd 降权到 `adbd_tradeinmode` 域，只允许 `shell tradeinmode`）。完整定位过程和解法见 `05-adb-tradein.md`。

一句话结论：**这是安全设计，不是 bug；但代价是冷启动会恢复出厂，所以产品必须用快照启动。**

### 2. 部分按钮点不动 —— 结论修正

早先判断是「鼠标事件到不了 Unity 表面」，**这个判断是错的**。后续实验推翻了它：

- 设置页面切换：`adb shell input swipe` 成功
- Clash of Clans 协议弹窗：先在正文区 `input swipe` 滚动到底，再 `input tap`「同意」——**成功进入下一屏**

真实原因是**按钮状态门控**：国内游戏/系统弹窗常要求协议正文滚动到底才启用按钮，视觉上按钮是绿的（看起来可用），实际点击被吞。这类现象极易被误判成「输入通道坏了」。

因此输入层的正确顺序是：**adb `input` 优先，QMP 指针兜底**（见 `engine/andropod/input.py`）。`input` 走 InputManager，能到所有表面；QMP 只到接受模拟指针事件的表面，但它在 adb 还没起来时可用。

`virtio-multitouch-pci` 仍然挂在虚拟机上（客户机能认到 `QEMU Virtio MultiTouch`，`ABS_MT_POSITION_X/Y` 范围 0..32767），但 **QMP `mtt` 事件送不出坐标**。

参数形状已经摸清（靠 QEMU 的报错逐项反推，五个字段全部必填、且是扁平结构）：

```json
{"type":"mtt","data":{"type":"begin","slot":0,"tracking-id":0,"axis":"x","value":16383}}
```

`axis` 只接受 `x` / `y`，其它值报 `Parameter 'axis' does not accept value`。

试过四组相位语义（`scripts/mtt_probe.py` 可复现），内核都只收到：

```
EV_ABS  ABS_MT_TRACKING_ID  00000000
EV_SYN  SYN_REPORT
```

**坐标值被丢弃**——整个序列只合成一个 SYN_REPORT，位置事件从不出现。判断是这个 QEMU 构建的 `mtt` 通路只处理触点生命周期，不处理坐标。因此输入主路径保持 adb `input`，QMP 的 `abs` + `btn` 作为 adb 未就绪时的兜底。

### 3. 显示分辨率偏低

1280×800 是 virtio-gpu 的默认值。产品化需要可配置（`-device virtio-gpu-pci,xres=,yres=`）以及 DPI 缩放。

## 复现命令

```bash
./bin/andropod import-utm --zip runtime/images/lineage-utm-arm64.zip --name lineage
./bin/andropod start --name lineage --wait-for __none__
./bin/andropod shot /tmp/a.png --name lineage
./bin/andropod tap 640 686 --name lineage
./bin/andropod key ret --name lineage
./bin/andropod stop --name lineage
```
