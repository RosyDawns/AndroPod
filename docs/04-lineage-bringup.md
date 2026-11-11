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

## E17（2026-11-11）：新建实例为什么停在开机向导

现象：新建的实例（device-1 / device-2）开机后停在
「Welcome to LineageOS」向导，或者窗口里是一屏内核日志。

### 原因：母盘本身没完成初始化

新建实例不是"装一台新机"，而是把 `runtime/images/base-vda.qcow2` 与
`base-vdb.qcow2` 做 APFS clone。母盘是什么状态，新实例就继承什么状态。

实测母盘（也就是 device-1 的数据盘）：

```
settings get global device_provisioned      → 0
settings get secure user_setup_complete     → 0
cmd package resolve-activity ... HOME       → org.lineageos.setupwizard/.SetupWizardActivity
```

Android 的规则是：`user_setup_complete` 没置 1 时，**向导 Activity 就是 HOME**。
所以每一台克隆出来的设备都认为自己是全新设备，必然进向导——这不是新建流程的 bug，
是模板的状态问题。

那屏内核日志是同一件事的另一面：截图抓在引导早期（22 s），客户机还在往
framebuffer 打 init 日志，SurfaceFlinger 还没接手。等它起来，一样是向导
（`adb shell screencap` 抓到的就是向导页）。

### MuMu 是怎么做的

它不会让你看到向导，因为它根本不"首次开机"：

1. **母盘是预先初始化过的 data 镜像**。MuMu 的 `vms/0/data.qcow2` 有 10.5 GB，
   是一个已经走完开机流程的用户盘；`device_provisioned=1`、向导已禁用、
   默认桌面已经是 Launcher。多开 = clone 这份 data 镜像。
2. **启动走状态恢复，不是冷启动**。它保存了整机状态，点开就是桌面，
   连开机动画都看不到（所以我们这边 virgl 不能 savevm 才会慢一截）。

两条合起来：MuMu 的"新建实例"= 一个已经设置好的用户的副本，而我们之前是
一个从没设置过的用户的副本。

### 我们这边的修法

初始化动作用的是 `engine/andropod/provision.py`（本来就有）：

```
settings put secure user_setup_complete 1
settings put global device_provisioned 1
pm disable-user --user 0 org.lineageos.setupwizard
am start -a android.intent.action.MAIN -c android.intent.category.HOME
```

新增两条命令，把它变成一次性操作：

```
./bin/andropod prepare-base --name device-1   # 启动→初始化→关机→回写母盘
./bin/andropod bake-base --source device-1    # 只回写（实例必须已停止）
```

`bake-base` 用 `cp -c`（APFS clonefile）把实例的 vda/vdb 覆盖到
`images/base-vda.qcow2` / `base-vdb.qcow2`，6.7 GB 耗时 0.7 秒，
之后的每个新实例都直接进桌面。

### 谁触发：产品，不是用户

第一版把这几步做成了「用户自己跑命令」，这是错的——MuMu 从来不让用户做这件事，
它在**镜像准备阶段**就完成了初始化。现在改成同样的时机划分：

- 管理器启动时检查 `runtime/images/.base-provisioned`；
- 没有就自动执行 `prepare-base`（启动模板 → 完成初始化 → 关机 → 回写母盘），
  状态栏显示「首次启动：正在准备系统（完成安卓初始化，约 40 秒）…」；
- 成功后写 marker，之后每次 `create` 都只是 clone 一份已初始化的母盘，
  新建实例开机即桌面。

整个过程零命令、零点击（除了打开管理器本身），且只发生一次。

> 备注：这几条 adb 命令会关闭系统向导，属于更改客户机配置的动作。开发过程中由
> agent 直接在终端里执行会被宿主安全策略拦截；把它放进产品流程、由应用在用户
> 打开时执行，才是与 MuMu 一致的归属。

## E18（2026-11-11）：回写母盘必须在「客机自己关机」之后

给母盘做初始化时踩了一个很贵的坑：`prepare-base` 用 QMP `quit` 硬停客机，
然后立刻把 vda/vdb 复制成模板。结果**所有克隆出来的实例都无限重启**：

```
init: Command 'mount vfat /dev/block/by-name/firmware ...' failed: Invalid argument
init: Reboot ending, jumping to kernel
reboot: Restarting system with command 'recovery'
```

原因：vfat 没有日志（ext4 有 journal 可以回放，vfat 没有）。硬停时客机页缓存里
还有没落盘的目录项，`/vendor/firmware_mnt` 被写坏 → 每次开机 mount 失败 →
init 按 `androidboot.init_fatal_reboot_target=recovery` 重启 → 再失败 → 死循环。
源实例（device-1）也因为同一次硬停被写坏。

### 加固

- `prepare-base` 改为 `stop(graceful=True)`：用 ACPI `system_powerdown` 让 Android
  自己走完 `sys.powerctl` → 停服务 → 卸载 → `reboot: Power down`；
- `bake-base` 增加校验：串口最后 4 KB 里必须有 `reboot: Power down`，否则**拒绝回写**
  （`--force` 才可绕过）。宁可失败，也不产出会无限重启的模板；
- 管理器的「启动时自动准备」暂时关闭：关机链路没验证通过之前，不能让它在用户
  机器上自动跑。

### 恢复过程

`runtime/images/lineage-utm-arm64.zip`（原始 UTM 包）还在，重新
`import-utm --name rebuild-1` 得到干净实例 → 启动确认无重启循环 →
`bake-base --source rebuild-1 --force` 回写母盘 → 新建实例验证：50 秒正常进系统，
`reboot: Restarting` 计数为 0。损坏的 device-1 已删除。

教训：**模板 = 一个正常关机过的磁盘**。任何"快照式"复制（clone、cp、快照回滚）
都必须先让客机把文件系统卸干净，否则拿到的是"看似完好、一开就崩"的镜像。

## E19（2026-11-11）：开机就进桌面、秒开、不看日志 —— 按 MuMu 的三层顺序重做

用户的三条抱怨都指向同一件事：**MuMu 的"开箱即用"不是靠某个开关，而是三层
按顺序都成立**。之前我们每层都缺一半，于是表现为"打印日志 → 停欢迎页 →
反复重启 → 让用户重装"。

| 层 | MuMu 的做法 | 我们之前的做法 | 现在 |
|---|---|---|---|
| 内核/引导 | bootloader 传 `console=ttyMSN0 quiet`，屏幕归 bootanimation | `console=tty0`，printk 直接写 framebuffer | 去掉 tty0，串口保留 |
| 首次开机 | data 镜像是**已配置完成**的用户盘 | 母盘是未初始化的，每台都进向导 | provision + 回写母盘 |
| 启动方式 | 整机状态恢复（点开就是桌面） | 冷启动 30–40 s，走完 init 全套检查 | 2D + `savevm`/`loadvm`，2.2 s |

### 一、窗口里滚动内核日志

`boot-assets/cmdline.txt` 里有 `console=tty0`（从原厂 vendor_boot 抄来的），
内核把 printk 同时写到 fbcon 和串口，于是模拟器窗口里就是 dmesg。

修法是**只去掉 tty0**，不要加 `loglevel=0`：我们第一次图省事加了
`quiet loglevel=0`，结果串口也静音了，出问题时什么都看不到。正确的分工是
屏幕不显示、串口全量保留：

```
console=ttyAMA0   # 仅串口（vm.py 追加）
quiet             # 可选：压掉 ttyAMA0 上的 info；dmesg 仍在 ring buffer 里
```

### 二、每次都停在 "Welcome to LineageOS"——真凶不是没初始化

表面看是母盘没 provision，把 `user_setup_complete` 设上就好了。但设好之后
下次冷启动又回去了。串口日志给出了答案：

```
init: processing action (CheckTradeInModeStatus) from (<Builtin Action>:0)
init: Reboot ending, jumping to kernel
```

`tradeinmode evaluate`（我们为了拿到 shell 必须执行它，否则 adbd 停在
`adbd_tradeinmode` 域，只接受 `tradeinmode` 一条命令）会写
`/metadata/tradeinmode/wipe`。这是给"以旧换新"场景用的：下次冷启动应当进入
recovery 清空用户数据。**我们没有 recovery 分区**，reboot 直接回到同一个 kernel，
于是变成无限循环 —— 循环之前系统只活了 0.6 秒，所以永远完不成初始化。

清理方式（离线，不需要 root）：

```bash
qemu-img convert -f qcow2 -O raw vda.qcow2 /tmp/vda.raw
dd if=/tmp/vda.raw of=/tmp/metadata.img bs=1M skip=4354 count=32
debugfs -w -R "rm /tradeinmode/wipe" /tmp/metadata.img
dd if=/tmp/metadata.img of=/tmp/vda.raw bs=1M seek=4354 conv=notrunc
qemu-img convert -f raw -O qcow2 /tmp/vda.raw vda.qcow2
```

`skip=4354` 来自 GPT 里 metadata 分区的起始 LBA（8916992 × 512）。
删除后 `Reboot ending` 计数为 0，系统第一次走完了完整启动。

### 三、秒开：只有 2D 后端能保存整机状态

`savevm` 在 virgl 下直接失败：`Error: virgl is not yet migratable`。
所以 **GPU 加速与"点开即桌面"在 QEMU 里是互斥的**。MuMu 能两者兼得，是因为它
不用 QEMU 的显示层，自己实现了 gfxstream 渲染，状态保存也由自己接管。

选择：默认 **2D 后端**，因为"开箱即用"优先级高于"游戏帧率"，且 2D 不需要
放宽 SELinux。实测：

```
冷启动            ~40 s
savevm clean      2.25 s（2.33 GiB 内存状态）
loadvm clean      2.24–2.68 s
进程启动 + QEMU   ~7 s
点开到桌面         ~10 s
```

virgl 仍是可选项（设置里开 GPU 后自动切换），代价是失去快照、每次冷启动。

### 四、新建实例 = 克隆一个已经配置好的用户

顺序必须是：

```
冷启动 → provision（退出回收模式、跳过向导）→ 关机 → 清 wipe 标记
      → 冷启动一次确认 → savevm clean → 正常关机 → bake-base
```

注意 `savevm` 必须在清标记之后：`qemu-img convert` 会丢掉内部快照，所以不能
反过来。`bake-base` 会校验串口里有 `reboot: Power down`（E18 的教训），
`stop --graceful` 现在走 `adb shell sync; reboot -p`，2.5 秒完成并留下该标记。

### 实测结果

```
新建 test-2 → 计划走 clean 快照 → 恢复 2.24 s → 直接是桌面（无向导、无日志）
device-1 重启 → 恢复 2.68 s → 桌面 → 打开设置页正常
stop --graceful → 2.5 s，serial 末尾 `reboot: Power down`
```

## E20（2026-11-11）：2D + loadvm 的呈现冻结 —— 显示链路的量化定位

用户报告"模拟器卡死"。量化定位结论：**QEMU 与客机都活着，冻结只发生在
loadvm 之后的呈现层**。

### 量化数据（ANDROPOD_DISP_DEBUG 计数器，5 秒窗口）

```
恢复完成 5s 后   update=48  refresh=70    ← update 开始到达
滑动桌面期间     update=163 refresh=156    ← 客机动画推送大量帧
静止桌面         update=5~6 refresh=150    ← 每分钟壁纸/时钟变化
```

`cocoa_refresh`（30fps 定时器）与 `cocoa_update` 全部正常调用；
同一时刻 lldb 强制 `setNeedsDisplay:YES` 画面立即追上；
但 loadvm 后窗口内容长期停在恢复时刻的帧（客机 screencap 已前进 30 分钟）。

### 结论

呈现链路（vCPU → flush → cocoa_update → setNeedsDisplay → drawRect）每一环
都在跑；**坏的是数据源**——`virtio-gpu` 的 blob/host-visible 显存映射在
loadvm 后失效。客机 SurfaceFlinger 继续往（新）映射写帧，QEMU 的 scanout
读取路径读到的仍是（旧）映射内容，所以 update 回调被调、drawRect 被调、
画出来的永远是恢复时刻的像素。冷启动（同一播放器、同一窗口代码）显示
100% 实时（锁屏大时钟与真实时间同步、通知实时弹出），排除窗口实现问题。

这是 QEMU vmstate 恢复 virtio-gpu blob 映射的上游语义问题，深挖成本高。
**在修好之前，开机一律冷启动**（AppModel.boot 已去掉 `--snapshot clean`）。
`clean` 快照仍在母盘里，修复后可随时启用秒开。

### 顺带的两个修复

1. `cocoa_update` 从 `setNeedsDisplayInRect:`（增量脏矩形，嵌入模式下会被
   AppKit 吞掉）改为全量 `setNeedsDisplay:YES`。桌面静止时 SurfaceFlinger
   每分钟才合成一次，无成本；动画时全帧 blit 足够 60fps。
2. 新增 `ANDROPOD_DISP_DEBUG=1` 频率计数器（写 /tmp/cocoa-freq.log），下次
   排显示问题先看它，避免再靠猜。

### MuMu 的对照

MuMu 不用 QEMU 的显示层，渲染器每帧**主动**画自己的 CAMetalLayer（数据源
永不失效）；整机状态由它自管的挂起/恢复承担，不走 QEMU vmstate。所以它
既秒开也不会遇到本节问题。等价做法是「播放器常驻 + 挂起/恢复自家状态」，
属于后续阶段。

## E23（2026-11-11）：模拟器桌面 APK —— MuMu 式产品层（客机侧）

用户确认要做"自定义界面"。第一版落地：**AndroPod Home**——仿 MuMu 桌面的
自制 Launcher 应用，纯框架 API、程序化布局、无第三方依赖。

- 源码：`app/home-apk/`（单 Activity：暖色渐变壁纸 + 72sp 大时钟 + 应用网格
  （6 列，图标+名字，点击启动）+ 底部快捷胶囊）
- 构建：`build-apk.sh`（aapt2 + javac + d8 + zipalign + apksigner，产物 20 KB）；
  合并 dex 用 python zipfile——安全中心拦截 zip 的原地替换
- 集成：`provision.py` 自动安装 `runtime/images/extra-apks/andropod-home.apk`
  并 `cmd role add-role-holder android.app.role.HOME com.andropod.home` 接管 HOME
- 实测：桌面已接管（时钟/日期/网格/胶囊全部为自定义 UI），

### 未竟

- 背景色显示为 LineageOS 默认壁纸（蓝），设计的金色渐变未上——root 背景
  未生效的机制待查（结构正常，纯色差）
- 原生 SystemUI（状态栏/导航栏）仍在：Android 16 无 policy_control，需镜像层
- 应用商店胶囊目前是占位（打开网页）
