# AndroPod

Apple Silicon 上的安卓模拟器，目标是 MuMu 的使用体验。

**当前状态**：Android 16（LineageOS 23.2）在 QEMU + HVF 下运行，画面直接渲染在
macOS 应用的窗口里（无第二个 QEMU 窗口），开机直达自定义桌面，Virgl 硬件加速
已实测 Unity 商业游戏 60 FPS。

## 架构

```
┌─ AndroPod.app ─────────────────────────────────────────────┐
│                                                            │
│  管理器进程（SwiftUI）            播放器进程 ×N（ObjC）      │
│  ┌──────────────────┐   播放    ┌─────────────────────────┐ │
│  │ 设备卡片列表      │ ────────▶ │ 窗口 + 工具条            │ │
│  │ 新建/删除/设置    │           │ ┌─────────────────────┐ │ │
│  │ 开关机            │           │ │  QEMU（动态库内嵌）  │ │ │
│  └──────────────────┘           │ │  画面直接挂进窗口    │ │ │
│                                 │ └─────────────────────┘ │ │
│                                 └─────────────────────────┘ │
└────────────────────────────────────────────────────────────┘
```

- **QEMU 以动态库形式内嵌在播放器进程里**（`libandropod-qemu.dylib`），
  客机视图直接挂进播放器自己的 NSView——不创建第二个窗口，输入直投。
- 一台实例一个播放器进程；管理器负责列表、创建、开关机。
- 进程间只通过实例目录里的文件协作（`qemu.cmd` / `plan.json` / `qemu.pid` /
  `window.json`），没有私有 IPC。

## 现在能做什么

- **单窗口模拟器**：画面铺满播放器窗口，右上角悬浮工具条
  （返回 / 最近任务 / 主页 / 音量± / 截图 / 安装 APK / 全屏）
- **新建即桌面**：新建实例 = 克隆已初始化的母盘（APFS clone，秒级），
  客机已配置好 AndroPod Home 桌面，开机不进设置向导
- **冷启动约 40 s 到桌面**；窗口关闭有确认弹窗，关机走双通道
  （QMP 优雅退出 + Android 自身 sync→umount→powerdown）
- **鼠标即触摸**：绝对坐标映射（usb-tablet），不抓取光标，可自由进出窗口
- **Virgl GPU 加速**（可选）：实测 Unity 商业游戏 60 FPS / janky 0.67%
  （E11，`docs/07-gpu-virgl.md`）
- **AndroPod Home**：自制模拟器桌面 APK（渐变壁纸 + 大时钟 + 应用网格），
  provision 自动预装并接管 HOME
- 全量快照（2D 后端）：`savevm` 2.3 s / `loadvm` 2.3 s

## 已知限制（如实）

- **默认后端是 2D（SwiftShader）**：UI 流畅；重 3D 游戏需在设置里切 Virgl，
  代价是失去快照能力（`virgl is not yet migratable`）且要求客机 SELinux 宽容
- **快照恢复（loadvm）下画面会冻结**：virtio-gpu 的 blob 显存映射在恢复后
  失效（QEMU 上游恢复语义问题，E20 有量化定位），因此当前开机一律冷启动
- **客机原生状态栏/导航栏仍在**：Android 16 已移除 policy_control，
  隐藏它们需要定制镜像（MuMu 是定制 build）
- 键鼠映射、批量多开、应用市场：未做

## 快速开始

依赖（一次性）：

```bash
brew install android-platform-tools meson ninja
brew install startergo/qemu-virgl/qemu-virgl   # virgl GPU 可选
```

获取安卓镜像与 QEMU 源码：

```bash
# 安卓镜像（LineageOS UTM 包，从 release 页下载到 runtime/images/）
./bin/andropod import-utm --zip runtime/images/lineage-utm-arm64.zip --name device-1

# QEMU 源码 + 补丁（嵌入引擎构建依赖，见 third_party/README.md）
cd third_party && curl -fLO https://download.qemu.org/qemu-10.1.2.tar.xz \
  && tar xf qemu-10.1.2.tar.xz \
  && curl -fLO https://raw.githubusercontent.com/startergo/homebrew-qemu-virgl/refs/heads/master/Patches/qemu-v07.diff \
  && cd qemu-10.1.2 && patch -p1 < ../qemu-v07.diff && cd ../..
```

构建并安装（自动安装到 /Applications，构建即生效）：

```bash
# 嵌入引擎（首次）
./engine/embed/build_libqemu.sh

# 应用（管理器 + 播放器 + 桌面 APK），完成后自动装到 /Applications
cd app && ./build.sh && open /Applications/AndroPod.app
```

命令行日常操作：

```bash
./bin/andropod list                          # 实例列表
./bin/andropod create --name d2 --cpus 4 --memory 6144 --xres 1600 --yres 945 --dpi 240
./bin/andropod provision --name device-1     # 初始化：退出回收模式/跳过向导/预装桌面
./bin/andropod plan --name device-1          # 生成启动计划（供播放器内嵌启动）
./bin/andropod start --name device-1         # 冷启动
./bin/andropod stop --name device-1 --graceful
./bin/andropod snap clean --name device-1    # 整机快照（2D）
./bin/andropod bake-base --source device-1   # 把已初始化实例回写为新建模板
```

## 目录结构

```
AndroPod/
├── bin/andropod            命令行入口
├── engine/
│   ├── andropod/           控制面：QMP 客户端、实例编排、plan、provision
│   └── embed/              QEMU 内嵌入口层 + 播放器（ObjC）+ 构建脚本
├── app/
│   ├── Sources/            管理器（SwiftUI，SwiftPM）
│   ├── home-apk/           AndroPod Home 桌面 APK（aapt2+javac+d8，无 gradle）
│   └── build.sh            构建并安装到 /Applications
├── runtime/
│   ├── images/             母盘、引导资源（kernel/initrd/bootconfig）、extra-apks
│   └── instances/<name>/   每实例的 overlay 盘、plan.json、socket、日志
├── third_party/            QEMU 源码树（1.8G，不入库；README 有获取步骤）
└── docs/                   实验记录 E1–E24（GPU、嵌入、性能、镜像接入）
```

## 关键设计决策

1. **QEMU 是播放器进程里的一个库**。单窗口体验（MuMu 同款）在"QEMU 子进程 +
   第二窗口"模型下做不到；`qemu_init` 在播放器进程内执行，主循环跑后台线程，
   主线程留给 AppKit。见 `docs/08-embed-single-window.md`。
2. **管理器 + 播放器双进程**。`qemu_init` 是进程级单例，多开只能多进程；
   崩溃隔离，管理器永不挂。
3. **状态走文件，不走 IPC**。`qemu.cmd`（argv）由引擎 `plan` 生成，播放器只改
   显示后端——CLI 与 GUI 的启动参数永远一致。
4. **关机双通道**。QMP `quit`（优雅刷盘）与 `adb shell sync; reboot -p`
   （Android 自身关机流程）并发发出，谁先完成都行；6 s 兜底 `_exit`。
   客机 ACPI 关机事件在本机型上被忽略（无 gpio-keys），`reboot -p` 才是正路。
5. **2D 默认，Virgl 可选**。可恢复性 > 峰值性能：只有 2D 能 savevm，
   且 2D 不需要放宽 SELinux。E11 实测 Virgl 下 Unity 游戏 60 FPS。
6. **不碰的东西**：不改 LineageOS 系统分区、不内置 root、镜像保持上游原样——
   所有产品行为（跳过向导、预装桌面）都通过 provision 在 data 层完成。

## 已测数据

| 项目 | 数值 | 说明 |
|---|---|---|
| 新建实例（克隆母盘） | 0.98 s | APFS clonefile |
| 整机快照 savevm / loadvm | 2.25 s / 2.3 s | 2.33 GiB 内存状态（2D 后端） |
| 点开到桌面（冷启动） | ~40 s | virgl 快照不可用期间的默认路径 |
| 911 MB APK 安装 | 4 s | 流式安装 |
| Virgl：Unity 游戏（E11） | 60 FPS / janky 0.67% | GPU 帧时间 P50 11 ms |
| qemu_init（进程内） | 125 ms | 含显示初始化 |
| 正常关机（graceful stop） | ~2.5 s | sync→umount→`reboot: Power down` |
| 帧率（2D，UI 场景） | 流畅 | SwiftShader 软渲染，全帧 blit |

## 文档索引

- `docs/04-lineage-bringup.md` — 镜像接入、向导死循环、母盘烘焙（E17–E23）
- `docs/07-gpu-virgl.md` — virgl 全程：E1→E13（含 MuMu 逆向与本机实测）
- `docs/08-embed-single-window.md` — QEMU 内嵌与单窗口：E14→E24
- `docs/06-performance.md` — 性能历史（VNC 时代数据仍在，供对照）

## 路线图

1. 修 loadvm 呈现冻结（virtio-gpu blob 恢复语义）→ 恢复秒开
2. 隐藏客机原生 SystemUI（vendor overlay / 定制镜像）
3. 播放器常驻 + 挂起（绕过冷启动，真正的 MuMu 秒开）
4. 键鼠映射、批量多开、应用市场
