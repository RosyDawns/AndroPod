# AndroPod

Apple Silicon 上的安卓虚拟机。工作代号，随时可改。

**当前状态：Android 已经完整跑通。** LineageOS 23.2（Android 16）在 QEMU + HVF 下启动、渲染、接受输入，ADB 可用，911 MB 的游戏 APK 4 秒装完并能启动到游戏首屏。

## 现在能做什么

- HVF 硬件加速启动 ARM64 虚拟机（QMP 握手 0.13s）
- 启动 **Android 16**，约 2 分钟到设置向导，1280×800 渲染
- 一条命令完成首次初始化：退出 ADB 回收模式、跳过设置向导、进桌面、装 APK
- 装 APK（流式，911 MB / 4 s）
- 通过 QMP 抓帧（PNG，3–8 KB/帧）和注入触控/按键
- 全量状态快照：`savevm` 2.78s，`loadvm` 2.78s
- macOS 原生壳：实例列表、启动停止、快照恢复、画面预览
- 一个实例一份 qcow2 overlay，基础镜像只存一份

## 还不能做什么

- 键盘鼠标映射、多开调度、GPU 3D 加速（Homebrew QEMU 无 virgl）
- **不能冷启动**：冷启动会进回收模式并在下次擦除数据，产品必须走快照启动
- QMP `mtt` 事件送不出坐标（只送触点生命周期），输入主路径走 adb `input`
- 应用放在桌面，每次重编译会触发 macOS 的「访问桌面文件夹」授权——后续应把 runtime 迁到 `~/Library/Application Support/`

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

- 缩略图是**实时画面**（8 fps 抓帧），未运行时显示「未开机」
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
```

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

## 已测数据

| 项目 | 数值 | 说明 |
|---|---|---|
| QMP 握手 | 0.13 s | 进程启动到可接受指令 |
| Android 开机动画 | ~30 s | |
| Android 到设置向导 | ~2 min | 首次启动，含 dex2oat |
| 退出 ADB 回收模式 | ~8 s | adbd 重启 |
| 911 MB APK 安装 | **4 s** | 流式安装 |
| 帧缓冲 | 1280 × 800 | virtio-gpu 默认 |
| 抓帧 | **4–7 ms** | 原始 PPM，见 `docs/06-performance.md` |
| 帧解码 | **0.5 ms** | vImage → CGImage |
| 端到端显示 | **7 ms/帧** | 上限 143 fps，实际按 30 fps 稳跑 |
| 输入注入 | **7 ms** | 常驻 `adb shell`，非每次起进程 |
| 保存/恢复全量快照 | 2.78 s / 2.78 s | 4 GB RAM |
| **从快照开机** | **3.1–3.6 s** | `-S` + `loadvm` + `cont`，客户机不引导 |
| Linux guest 冷启动 | 33–52 s | Alpine，用于回归 |

> 早先版本抓帧走 PNG，单帧 129 ms 且跑在 QEMU 主循环里，把客户机一起拖慢；点击走 Python CLI，一次最长 30 s。两条都已改掉，详见 `docs/06-performance.md`。

## 已知性能上限

渲染器是 **SwiftShader（纯 CPU）**。Homebrew 的 QEMU 不带 `virglrenderer`，没有 `virtio-gpu-gl-pci`，所以 3D/复杂合成只能软渲染。这是与商业模拟器（MuMu 等有完整 GPU 加速栈）的本质差距，调参无法弥补。轻量界面实测可达 68 fps 画面变化率，重图形负载才会暴露瓶颈。

## 下一步

1. 键鼠映射（把宿主键鼠转成 Android 输入）
2. 批量多开调度（overlay 已就绪，缺端口与资源分配）
3. 设备设置面板：分辨率 / CPU / 内存 / 机型指纹

见 `docs/02-roadmap.md`、`docs/03-image-survey.md`、`docs/04-lineage-bringup.md`、`docs/06-performance.md`。
