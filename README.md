# AndroPod

Apple Silicon 上的安卓虚拟机。工作代号，随时可改。

**当前状态：Android 已经完整跑通。** LineageOS 23.2（Android 16）在 QEMU + HVF 下启动、渲染、接受输入，ADB 可用，911 MB 的游戏 APK 4 秒装完并能启动到游戏首屏。

## 现在能做什么

- HVF 硬件加速启动 ARM64 虚拟机（QMP 握手 0.13s）
- 启动 **Android 16**，约 2 分钟到设置向导，1280×800 渲染
- 一条命令完成首次初始化：退出 ADB 回收模式、跳过设置向导、进桌面、装 APK
- 装 APK（流式，911 MB / 4 s）
- **VNC / ZRLE 增量显示通路**：只推变化矩形，动态场景 382 KB/s，静态近乎零流量
- 抓帧回退通路（原始 PPM，4–7 ms/帧），VNC 不可用时自动切换
- QMP 注入触控/按键，常驻 adb shell 发送 HOME/BACK/多任务
- 全量状态快照：`savevm` 2.78s，`loadvm` 2.78s
- macOS 原生壳：实例列表、启动停止、快照恢复、画面预览、实时 fps
- 一个实例一份 qcow2 overlay，基础镜像只存一份

## 还不能做什么

- 键盘鼠标映射、多开调度；**GPU 3D 加速已打通 virgl 通路**（`--gpu-backend virgl`，但有显示/SELinux 前置条件，见下）
- **不能冷启动**：冷启动会进回收模式并在下次擦除数据，产品必须走快照启动
- QMP `mtt` 事件送不出坐标（只送触点生命周期），输入主路径走 adb `input`
- **Unity 重图形负载仍会卡**：显示通路已优化，但客户机内部仍是 CPU 软渲染

## 界面

按 MuMu 模拟器的结构做，两层窗口：

**主窗口** —— 设备卡片列表

```
┌─────────────────────────────────────────────┐
│ 我的设备  3                    [+]  新建     │
├─────────────────────────────────────────────┤
│ ┌───────────────┐  ┌───────────────┐        │
│ │[缩略图] lineage│  │[缩略图] device-1│       │
│ │  4 核 · 4 GB  │  │  未开机        │        │
│ │1280×800·160DPI│  │               │        │
│ │          [▶][⋯]│  │          [▶][⋯]│        │
│ └───────────────┘  └───────────────┘        │
└─────────────────────────────────────────────┘
```

- 缩略图是**实时画面**（VNC 推流，静止时不消耗带宽），未运行时显示「未开机」
- `▶` 开关机；`⋯` 里有打开界面 / 初始化 / 快照 / 恢复
- 双击卡片打开设备窗口

**设备窗口** —— 双击卡片打开，右侧浮动工具条：返回 / 主页 / 截图 / 全屏 / 关机。画面区可直接点击和滑动。

对照 MuMu 的差距（还没做的）：键鼠映射方案、批量多开、应用市场、虚拟定位、分辨率切换、性能档位（低/中/高）。

## 快速开始

```bash
# 依赖（只需一次）
brew install qemu android-platform-tools

# 环境检查
./bin/andropod env

# 导入安卓镜像（1 GB，需先从 release 页下载到 runtime/images/）
./bin/andropod import-utm --zip runtime/images/lineage-utm-arm64.zip --name lineage

# 启动并首次初始化（退出回收模式 → 跳过向导 → 进桌面 → 装 APK）
./bin/andropod start --name lineage --wait-for __none__
./bin/andropod provision --name lineage --apk /path/to/app.apk

# 初始化完立刻打快照
./bin/andropod snap clean --name lineage

# 之后的开机都走快照：约 3.6 秒，且不触发恢复出厂
./bin/andropod boot --name lineage --snapshot clean

# 日常操作
./bin/andropod shot /tmp/screen.png --name lineage
./bin/andropod tap 640 686 --name lineage          # 优先走 adb input
./bin/andropod swipe 640 500 640 180 --name lineage # 滚动
./bin/andropod key BACK --name lineage
./bin/andropod restore clean --name lineage
./bin/andropod stop --name lineage

# 图形界面
cd app && ./build.sh && open build/AndroPod.app

# 自检（含 VNC 与 screendump 两条显示通路）
ANDROPOD_ROOT="$PWD" app/.build/release/AndroPod --self-test
```

VNC 端口写在 `runtime/instances/<name>/instance.json` 的 `vnc_display`（实际端口 `5900 + N`）。新建实例会自动分配不冲突的号；`create --no-vnc` 可关闭，`create --vnc-display N` 可指定。旧实例没有该字段时，GUI 会自动回退到 `screendump` 抓帧。

也保留了一条纯 Linux 的快速验证路径（19 MB，30 秒启动），用来回归控制面本身：

```bash
./bin/andropod fetch
./bin/andropod smoke        # 12 项断言
```

## 目录结构

```
AndroPod/
├── bin/andropod          命令行入口
├── engine/andropod/      控制面：QMP 客户端、实例编排、镜像导入
├── app/                  macOS 原生壳（SwiftUI，SwiftPM 构建，无需 Xcode）
├── runtime/
│   ├── images/           内核、initramfs、安卓镜像
│   └── instances/<name>/ 每个实例的 overlay 盘、固件变量区、socket、日志
└── docs/                 架构、许可边界、路线图、镜像调研、接入实测
```

## 关键设计约束

1. **QEMU 只作为子进程，永不链接**。所有交互走 QMP / ADB 这类公开协议。见 `docs/01-license-boundary.md`。
2. **一个实例一个进程**。崩溃隔离、资源可回收。
3. **三条 QMP 通道**。QMP socket 一次只接受一个客户端，所以控制面 `qmp.sock`、显示面 `qmp-display.sock`、输入面 `qmp-input.sock` 各自独立——点击不必排在快照或状态查询后面。
4. **输入优先走 adb，不走 QMP 指针**。QEMU 的绝对坐标缩放后与客户机像素对不上（偏移量还不稳定），而 `input tap` 直接说像素；`input keyevent 3/4/187` 能发 HOME/BACK/多任务，QEMU 的 HID 键盘根本没有这三个键。
5. **adb 用自己的 server 端口（5599）**。默认 5037 常被残留 daemon 占住，表现是 `devices` 正常但所有命令挂死。新端口上设备必须先 `adb connect`。
6. **一个客户机只挂一个指针设备**。绝对坐标 + 相对设备并存会让坐标变成位移。
7. **显示优先走 VNC / ZRLE，而不是 screendump 轮询**。`screendump` 每帧全屏 3 MB 且跑在 QEMU 主循环里；VNC 按 damage 只推变化矩形，静态时几乎零流量。两条通路并存，VNC 收到首帧后抓帧循环永久退役，VNC 不可用则自动回退。客户端只用系统 zlib，不链接 QEMU。见 `docs/06-performance.md` 第九节。

## 已测数据

| 项目 | 数值 | 说明 |
|---|---|---|
| QMP 握手 | 0.13 s | 进程启动到可接受指令 |
| Android 开机动画 | ~30 s | |
| Android 到设置向导 | ~2 min | 首次启动，含 dex2oat |
| 退出 ADB 回收模式 | ~8 s | adbd 重启 |
| 911 MB APK 安装 | **4 s** | 流式安装 |
| 帧缓冲 | 1280 × 800 | virtio-gpu 默认 |
| **VNC / ZRLE 动态带宽** | **382 KB/s** | 31.6 fps，只推变化矩形 |
| VNC Raw / Hextile / Tight | 2196 / 1523 / 331 KB/s | 同场景对照 |
| screendump 全屏轮询 | ~90 000 KB/s | 30 fps × 3 MB，无论画面是否变化 |
| **VNC 帧构建** | **0.22–0.59 ms** | 增量合成 → CGImage，动态实测 32.2 fps |
| 抓帧（回退通路） | **4–7 ms** | 原始 PPM，见 `docs/06-performance.md` |
| 帧解码（回退） | **0.5 ms** | vImage → CGImage |
| 输入注入 | **7 ms** | 常驻 `adb shell`，非每次起进程 |
| 保存/恢复全量快照 | 2.78 s / 2.78 s | 4 GB RAM |
| **从快照开机** | **3.1–3.6 s** | `-S` + `loadvm` + `cont`，客户机不引导 |
| Linux guest 冷启动 | 33–52 s | Alpine，用于回归 |

> 早先版本抓帧走 PNG，单帧 129 ms 且跑在 QEMU 主循环里，把客户机一起拖慢；点击走 Python CLI，一次最长 30 s。两条都已改掉，显示通路后来又整体换成 VNC 增量推流。详见 `docs/06-performance.md`。

## GPU 加速：已打通（2026-11-10）

2D 实例的渲染器是 **SwiftShader（纯 CPU）**；**virgl 实例已跑通宿主 Apple GPU**——实测 `GLES: Mesa, virgl (ANGLE (Apple M2 Pro, OpenGL 4.1 Metal))`，AndroPod CLI 全链路验证锁屏/桌面正常渲染（`docs/07-gpu-virgl.md`，实验 E1→E10）。

**真实 Unity 商业游戏已验证（E11）**：《万龙觉醒》（Unity 2022.3.62f3 / IL2CPP / 2.07GB）在 virgl 实例上安装、冷启动、渲染全程 0 crash，GL 上下文为 `OpenGL ES 3.0 Mesa 25.3.3`（virgl 真硬件路径而非 SwiftShader），登录页大纹理渲染正确，帧率 ≈60 FPS / janky 0.67% / GPU 帧时间 P50 11ms。

创建 virgl 实例：`./bin/andropod create --name gpu1 --gpu-backend virgl`（需 `brew install startergo/qemu-virgl/qemu-virgl`，且客户机 GRUB 带镜像上游的 permissive 图形开关）。与 2D 实例的差异（QEMU 硬限制）：显示走 QEMU cocoa 窗口（`cocoa,gl=es`），无 VNC 串流、QMP screendump 抓不到 GL 内容（GUI 内嵌画面暂不支持 virgl 实例）。

方案 C（VNC/ZRLE 串流）解决「画面搬到宿主窗口」；virgl 解决「客户机内部渲染」。两者正交，2D 实例继续走 VNC 快路径。

## 下一步

1. **3D 场景性能实测**：登录页已达 60 FPS（E11）；登录账号进入 3D 主城/战斗场景，量化重负载下 GPU 收益
2. enforcing 验证：`adb screencap` 重验 enforcing 下渲染（E9 的黑帧已证明是 screendump 工具局限）；必要时给镜像打 udmabuf sepolicy 补丁
3. 键鼠映射（把宿主键鼠转成 Android 输入）
4. 批量多开调度（overlay 已就绪，VNC 端口已自动分配，缺资源调度）

见 `docs/02-roadmap.md`、`docs/03-image-survey.md`、`docs/04-lineage-bringup.md`、`docs/06-performance.md`。
