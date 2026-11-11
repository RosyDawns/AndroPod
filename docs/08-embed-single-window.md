# E14（2026-11-10）：把 QEMU 变成库 —— 单窗口嵌入实测

用户选 A 路线：不要 QEMU 那个独立窗口，画面必须进自己的窗口。本节记录**已验证**
的做法、构建配方和踩过的坑。

## 结论（已实测）

- `qemu_init()` 在宿主的**主线程**跑完只用 **125 ms**，随后把 BQL/replay 锁交出，
  QEMU 主循环在**后台线程**运行；主线程留给我们自己的 `NSApplication`。
- 客机 Android 的界面直接渲染进宿主的 `NSView`，**没有第二个窗口**。
  证据：`docs/assets/e14-embed-single-window.png`（状态栏 9:27、USB 调试弹窗、
  导航栏，窗口标题是我们的）。
- 首帧延迟：`andropod_qemu_start` 返回后 2 s 内 `QemuCocoaView` 已可成为
  第一响应者（键盘输入直接进客机）。

## 关键认知：QEMU 在 Darwin 本来就是这个结构

`system/main.c` 写得很清楚：

```c
if (qemu_main) {
    qemu_thread_create(&main_loop_thread, "qemu_main", qemu_default_main, ...);
    return qemu_main();          /* macOS: CFRunLoopRun / cocoa: [NSApp run] */
}
```

主线程留给 UI，QEMU 主循环在后台线程 —— 这正是 MuMu 的进程内模型。
我们只要**不接管 UI 主循环**（不设 `qemu_main = cocoa_main`），把视图塞进宿主窗口即可。

## 构建配方

```bash
# 1. 上游源码 + virgl 补丁（Homebrew qemu-virgl 用的就是它）
curl -O https://download.qemu.org/qemu-10.1.2.tar.xz && tar xf qemu-10.1.2.tar.xz
curl -o qemu-v07.diff \
  https://raw.githubusercontent.com/startergo/homebrew-qemu-virgl/refs/heads/master/Patches/qemu-v07.diff
patch -p1 < qemu-v07.diff     # 给 ui/cocoa.m 加 CAOpenGLLayer / EGL(ANGLE) 渲染

# 2. 配置：必须关 pvg；EGL 头要额外给 homebrew include
../configure --target-list=aarch64-softmmu \
  --disable-docs --disable-guest-agent --disable-tools \
  --disable-gtk --disable-sdl --disable-pvg \
  --extra-cflags=-I/opt/homebrew/include \
  --enable-opengl --enable-virglrenderer

ninja -j8 qemu-system-aarch64

# 3. 从 ninja 的链接行直接生成动态库
#    去掉 system_main.c.o（它带 main()）、去掉 -exported_symbols_list（会藏符号）
./engine/embed/build_libqemu.sh      # 产出 engine/embed/libandropod-qemu.dylib (36 MB)
```

## cocoa.m 的 5 处改动（`engine/embed/` 之外，在 QEMU 源码里）

1. 新增 `qemu_cocoa_set_host_view(void *nsview)` + 全局 `qemu_host_view`。
2. `QemuCocoaAppController initWithCGL:`：有宿主视图时不建 `NSWindow`，
   改为 `[hostView addSubview:cocoaView]`（autoresizing 跟随）。
3. `resizeWindow`：嵌入时不再改窗口尺寸，只 `setBoundsSize:` 让内容铺满。
4. `cocoa_display_init`：嵌入时跳过 `TransformProcessType`、`[NSApp setDelegate:]`、
   建菜单、以及 `qemu_main = cocoa_main`。
5. 标题：只在非嵌入模式设置，避免覆盖宿主窗口标题。

## 入口层（`engine/embed/andropod_qemu.c`）

```c
stage("init begin");
qemu_init(argc, argv);        /* 主线程 */
bql_unlock();                 /* 交锁给主循环线程，见 system/main.c 注释 */
replay_mutex_unlock();
pthread_create(&t, NULL, andropod_loop, NULL);   /* 里面 replay_lock + bql_lock + qemu_main_loop */
```

## 五个必须知道的坑

| 现象 | 原因 | 处理 |
|---|---|---|
| `Could not access HVF` | 进程没有 hypervisor 授权 | 用 QEMU 的 `accel/hvf/entitlements.plist` 给**宿主可执行文件**签名 |
| `failed to find romfile efi-virtio.rom` | 进程内 argv[0] 不是 qemu-system-aarch64，找不到自带固件 | 显式传 `-L <pc-bios>` |
| `Couldn't open libEGL.dylib` | ANGLE 的 EGL 是 `dlopen("libEGL.dylib")` | rpath 或 `DYLD_FALLBACK_LIBRARY_PATH=/opt/homebrew/opt/libangle/lib` |
| `unrecognized selector -[QemuCocoaView updateBounds]` | virgl 补丁删掉了这个方法 | 改用 `setBoundsSize:` |
| `_qemu_main` / `_bql_lock` 未定义 | 前者在 `system/main.c`（被排除），后者是宏 | 自己定义 `int (*qemu_main)(void);`；调用 `bql_lock_impl(__FILE__,__LINE__)` |

另两个构建坑：`hw/display/apple-gfx.m` 在 macOS 27 SDK 上因 `PGNewDeviceWithDescriptor`
被标记 obsolete 而编译失败 → `--disable-pvg`；`ui/egl-headless.c` 找不到
`EGL/eglplatform.h` → `--extra-cflags=-I/opt/homebrew/include`。

## 为什么 virgl 下画面还是黑的

嵌入路径本身没问题：`qemu_egl_init_dpy_cocoa` 与 `qemu_egl_init_surface` 都成功，
2D 设备下同一套窗口代码能正常出画。黑屏是因为 `device-2` 的
`selinux_permissive = False` —— 与 E9/E13 是同一个原因：enforcing 下 virgl 需要
udmabuf 映射，被 SELinux 拒掉，SurfaceFlinger 起不来。

也就是说：**单窗口嵌入已通，GPU 那条链只等客机侧那两个开关**（GUI 里的
「启用并开机」会写 `insecure_adb` + `selinux_permissive`）。

## 还没做的（接入 GUI 前必须定）

1. **多实例模型**。一个进程只能跑一个 QEMU（`qemu_init` 是单例）。MuMu 的做法是
   管理器进程 + 每个实例一个播放器进程，每个播放器内嵌自己的 QEMU。
   我们的 GUI 现在是「一个进程管多个子进程」，接入后要么改成同样的
   「管理器 + 播放器」，要么退化成一次只跑一台。
2. **退出语义**。`qemu_default_main` 结束时调用 `exit(status)`，在进程内会带走
   GUI；需要改成回调 + 自行清理（或让播放器进程独立，天然隔离）。
3. **打包**：`libandropod-qemu.dylib`、`pc-bios/`、`libEGL.dylib`、`libGLESv2.dylib`
   都要进 app bundle 的 Frameworks/Resources，并设好 rpath。
4. **签名**：app 主可执行文件必须带 `com.apple.security.hypervisor`。

## E15（2026-11-10）：管理器 + 播放器，已接入

上一节列的四个「还没做」全部落地。结构确定为 **一个管理器 + 每实例一个播放器进程**：
`qemu_init` 是进程级单例，多开只能靠多进程。

```
AndroPod.app/Contents/MacOS/
  AndroPod              管理器：列表、设置、开关机
  andropod-player       播放器：内嵌 QEMU，一台实例一个进程
  libEGL.dylib           ANGLE（GL 层是 dlopen，按可执行文件目录查找）
  libGLESv2.dylib
Contents/Frameworks/
  libandropod-qemu.dylib QEMU 10.1.2 + virgl 补丁，36 MB
Contents/Resources/pc-bios/   81 个固件/ROM 文件
```

### 进程间契约（全部是实例目录里的文件，没有私有 IPC）

| 文件 | 写方 | 读方 | 作用 |
|---|---|---|---|
| `qemu.cmd` | `andropod plan` | 播放器 | 完整 argv，播放器只改显示后端 |
| `plan.json` | `andropod plan` | 播放器 | 实例名、快照、QMP 路径、分辨率 |
| `qemu.pid` | 管理器 / 播放器 | 两边 | 存的是**播放器**的 pid |
| `window.json` | 播放器 | 播放器 | 窗口位置与尺寸（拖动后 0.4 s 落盘） |
| `snapshot-invalid` | 播放器 | `plan` | 快照不可恢复的否决票，下次直接冷启动 |
| `player.log` | 播放器 | 人 | stdout/stderr |

新增 `andropod plan --name X [--snapshot T]`：只做「fork 之前」的事——
清残留 pid/socket、构 argv、落 `qemu.cmd`、判断能不能走快照——**不启动任何进程**。
`start` 改为复用 `plan()`，两条路径的 argv 从此不会漂移。

### 三个必须记住的坑

1. **`qemu_cleanup()` 不退出进程。** 它只关块设备和 monitor，`exit(status)` 是
   `system/main.c` 里 `main()` 的活。嵌入层自己就是那个 `main()`，一开始漏了这步，
   表现是：QMP `quit` 之后 QEMU 主循环没了、窗口还在、`andropod stop` 20 s 超时。
   现在主循环返回后调用 `_exit(status)`——用 `_exit` 而不是 `exit`，因为 atexit
   会去拆 AppKit/GL 状态，和仍在跑的主线程死锁。盘已在 `bdrv_close_all()` 里刷过。
2. **ANGLE 是 dlopen 的，rpath 不生效。** dyld 对裸名 `libEGL.dylib` 会搜
   主可执行文件所在目录，所以两个 .dylib 必须和 `andropod-player` 同级放进
   `Contents/MacOS/`，而不是 `Frameworks/`。`DYLD_FALLBACK_LIBRARY_PATH` 由管理器
   传给子进程（dyld 只在 exec 时读，进程内 setenv 来不及）。
3. **`pc-bios` 要拷源树，不是 build 树。** `build/pc-bios` 只有 18 个生成的 EDK2
   镜像，`efi-virtio.rom` 等 ROM 在源码树里。拷错了的表现是启动即
   `failed to find romfile "efi-virtio.rom"`。

### 顺带发现：virgl 下快照只有磁盘，没有内存

`savevm` 返回 `Error: virgl is not yet migratable`。也就是说开 GPU 的实例
**永远无法保存虚拟机内存状态**，`clean`/`configured` 这两个快照都是 disk-only
（`qemu-img snapshot -c` 的产物），`loadvm` 只会得到
`This is a disk-only snapshot`。所以：

- 现在 `plan` 对 virgl 实例直接跳过快照，冷启动（约 25–40 s），并把原因写进状态栏；
- `savevm`/`loadvm` 开始检查 HMP 的返回文本（HMP 的错误是字符串，不是 QMP error，
  之前会「成功」但什么都没写）；
- 想要 MuMu 那种秒开，只能走「播放器常驻 + 挂起」而不是 QEMU 快照，属于下一阶段。

### 实测

```
plan    → virgl 后端不支持保存虚拟机内存状态，本次冷启动
播放器  → qemu_init 返回，窗口 device-1 1391×917 onscreen=true
管理器  → /tmp/andropod-gui.txt: running=device-1, displayMode=device-1=GPU
stop    → 1.1 s 全程，播放器进程退出，窗口消失，running 清空
window.json 落盘 {x:231,y:224,w:1119,h:686}
```

## E16（2026-11-11）：画面终于铺满 —— 三层几何必须对齐

E15 之后窗口是单进程单窗口了，但画面要么缩在左下角、要么放大裁切。根因是
**三个尺寸各说各话**：

| 层 | 谁决定 | 当时的取值 |
|---|---|---|
| EGL surface | ANGLE，按 `layer.bounds × contentsScale`，只在 display_init 建一次 | 创建时视图还是控制器的 **640×480** 默认值 |
| 视图坐标空间（bounds） | cocoa `resizeWindow` | 客机分辨率 1600×945 |
| swap layer | ANGLE 每次 swap 按 drawable 像素重设，`contentsScale=1` | 1600×946 点（内容按 1:1 像素贴左下角） |

只要三者不完全相等，就会出现「画面只占左下角」或「放大裁切」。之前偶然对过一次，
是因为窗口恰好等于 800×473 点（= 1600÷2），三个数碰巧一致。

### 最终做法（三处改动）

1. **客户机换模式时重建 surface**（`cocoa_gl_resize_surface`）。cocoa 上游只在
   display_init 建一次，之后永远不管；这是 cocoa 与 MuMu 自研后端最本质的差别。
2. **视口以 surface 为准**（`eglQuerySurface`）。`convertSizeToBacking` 在嵌入视图上
   返回点数，而 surface 是点数 × contentsScale，用它当视口只有左下角 1/4 被覆盖。
3. **swap layer 每帧校正**：`bounds = 视图 bounds`（客机像素）、`contentsScale = 1`、
   锚点居中。CAImageQueue 的内容是 1:1 像素贴图，图层等于坐标空间时才铺满。

重建要在 QEMU 主循环线程做，所以 `qemu_cocoa_relayout()` 只是 schedule 一个 BH；
BH 里重建完还要 `gl_dirty = true` + `dpy_gfx_update_full()`，否则静止画面（欢迎页）
不会重绘，窗口里留着旧尺寸那一帧。

### 窗口尺寸的硬约束

窗口必须等于 **客机像素 ÷ 屏幕缩放**（1600×945 → 800×473 点），三层才天然对齐。
想做更大的窗口，改客机分辨率（`kms_display_resolution`）而不是拉窗口——
拉窗口需要重建 surface 且 ANGLE 会重设图层，目前运行中改尺寸仍会花屏，所以窗口
暂时固定尺寸（不可拖拽）。这是已知限制，不是回归。

### 实测

```
窗口 device-1 800×505（内容 800×473） · 只有一个窗口 · 无 "Display output is not active"
[gl] view=800x473 vp=1600x946 surf=1600x946   ← 三个数一致
欢迎页完整铺满，状态栏在右上角
```

## E21（2026-11-11）：MuMu 式产品壳 —— 工具栏 + 画面居中

用户指出 MuMu 不是把原生安卓界面搬过来：它是产品壳（左侧工具栏 + 画面居中
+ 无原生 chrome）。本轮对齐了壳和工具栏，guest chrome 隐藏留待下一步。

### 已落地

窗口结构：52pt 深色侧栏 + 画面区。侧栏按钮（SF Symbols）：

| 按钮 | 动作 | 实现 |
|---|---|---|
| 返回/主页/最近任务 | `adb shell input keyevent 4/3/187` | adb_run（后台 NSTask，serial 从 qemu.cmd 的 hostfwd 解析） |
| 音量+/− | keyevent 24/25 | 同上 |
| 截图 | `screencap` + `pull` → `~/Desktop/AndroPod-时间戳.png` | 完成后弹窗提示 |
| 安装 APK | NSOpenPanel → `adb install -r` | sheet 进度 + 结果弹窗 |
| 全屏 | `toggleFullScreen:` | 系统全屏 |

画面不再铺满窗口：`fitGuestView` 按客机分辨率等比缩放居中（2D 渲染是 CGImage
按视图坐标绘制，任意尺寸都成立；virgl 的 EGL surface 由既有 relayout 跟随）。

实测：主页键把锁屏切回桌面（dumpsys mCurrentFocus=launcher3），窗口画面实时
跟上（时钟同步）；侧栏与画面区在 resize 下布局正确。

### 未落地（如实）

`settings put global policy_control immersive.full=*` 在 Android 16（LineageOS 23）
上无效——该机制 Android 11 后已移除。MuMu 没有原生状态栏/导航栏是因为它是
定制 build（SystemUI 直接不带），不是设置出来的。可选路径：换用带 root 的
镜像后 overlay 隐藏 SystemUI，或定制 vendor overlay；每条都要动镜像层，
留作后续。

### E21b：第一版工具栏推倒重来（用户对照 MuMu 截图）

第一版做成了「左侧竖栏 + 画面黑边居中」，与 MuMu 实际形态（右上角横向悬浮
工具条 + 画面顶满窗口）完全不符，图标布局也有堆叠 bug。按 MuMu 截图重做：

- 工具条：右上角悬浮，半透明黑胶囊（cornerRadius 18），横排 NSStackView：
  ◀ 返回 · ▣ 最近任务 · ⌂ 主页 | 🔊 🔉 | 📷 截图 · ⬇ 安装 APK | ⛶ 全屏
- 画面：铺满整个窗口（`fitGuestView` 只匹配 QemuCocoaView 类，等比交给窗口
  比例——初始窗口就是客机分辨率 ÷ backing）
- 层级：QEMU 视图在 qemu_init 时才挂进 gScreen（晚于工具条），每次 relayout
  把工具条重新提到 `NSWindowAbove`，保证永远浮在画面之上

已知重叠：工具条与客机自己的状态栏（右上角时钟/电量）在同一区域——MuMu 无此
问题是因为它的客机没有原生 chrome；等 E21 的镜像层隐藏方案落地后自然错开。

## E22（2026-11-11）：鼠标"卡在边缘/点击失效"——绝对指针模式

用户报告鼠标移不到边缘、点击异常。根因是上游 cocoa 的**抓取（grab）模型**与
模拟器体验冲突：

1. `mouseEntered` 一进画面就 `grabMouse` → `hideCursor` → **光标消失**；
2. `handleMouseEvent` 要求 `isMouseGrabbed` 才处理 → 光标看不见还在"工作"；
3. `mouseUp` 又会 grab → 用户无法解除（上游要 Ctrl+Alt+G）；
4. 坐标换算 x/y 共用一个缩放比（`screen.height / frame.height`）——窗口被
   resize 成非等比后**点击位置错位**。

嵌入模式（qemu_host_view 存在）改为**纯绝对指针**：

- `mouseEntered` / `mouseUp` / `grabMouse`：不抓取、不藏光标，光标可自由进出
  窗口边缘（`isMouseGrabbed` 恒为 NO，事件不再被 QEMU 劫持）；
- `handleMouseEvent` 在嵌入模式下无条件处理，绝对坐标 **x/y 各自缩放**；
- usb-tablet 是绝对指针设备，与触摸屏语义天然匹配。

### 顺带修掉：磁盘自锁

重建后启动报 `Failed to get "write" lock`——file-posix 的 flock 按 open file
description 计，QEMU attach 块设备 reopen 同一文件时与自己刚加的锁冲突
（macOS 特性）。`-drive` 生成改为带 `file.locking=off`（vm.py 固化），
双开保护由 pid 文件 + 管理器负责。

### 实测

```
isMouseGrabbed = NO（lldb 确认，鼠标进/出/点击后依然 NO）
时钟 04:35 与真实时间同步（冷启动实时）
file.locking=off 后启动无锁错误
```

## E24（2026-11-11）：关闭确认弹窗 + 关闭卡死修复

用户要求：点左上角关闭 → **先弹确认**（取消=不关、确认=才关）。

同时修掉两个让"点了没反应"的 bug：
1. shutdown 的 QMP `quit` 之前没有 `qmp_capabilities` 握手——QMP 规范要求
   连接后先握手，否则命令一律被拒，客机根本收不到关机指令；
2. 4 秒兜底的 `[NSApp terminate:]` 会被自己的 `windowShouldClose`（无条件
   返回 NO）取消——AppKit 终止流程会再向每个窗口确认，于是进程永远挂着。
   兜底改为 `_exit(0)`（atexit 死锁问题见 E15），且终止流程中窗口放行。

现在的交互：点 × / Cmd+Q → sheet「要关闭 device-1 吗？」→ 取消=窗口保留；
确认=客机正常关机（capabilities + quit）→ 主循环退出 → 进程 _exit。

## E25（2026-11-11）：virgl GPU 显示冻结 —— 双头布局管理震荡

用户开启 GPU 加速（virgl）后冷启动，窗口停在开机动画帧；客机一切正常
（boot_completed=1、SurfaceFlinger 在跑、时钟前进）。期间我曾错误地把实例
切回 2D——用户明确纠正：**开 GPU 就是要玩 3D 游戏，2D 不可接受**。

### 量化定位（ANDROPOD_DISP_DEBUG 计数器通用化后）

```
glrefresh=138/5s   ← 30fps 主循环正常
scanout=2 flush=2  ← 锁屏静止时客机只推分钟帧（正常节能）
render=15 swapfail=0 ← EGL 渲染 + swap 无失败
```

链接路每一环都健康，坏的是**布局管理权分裂**：

- QEMU 侧 `resizeWindow`（嵌入分支）：每次表面变化把视图 bounds 强设为
  **客机像素**（1600×945，E14 时代"窗口=像素"的遗产）
- player 侧 `fitGuestView`（E21b 引入）：每次布局把 frame 设回**窗口点尺寸**
  （800×473）

两边互相触发：setBounds → AppKit 通知 → fitGuestView 改回 → QEMU 下次
resizeWindow 再改……EGL surface 在两个尺寸间反复销毁重建（resized 计数
11/5s），ANGLESwap layer 被 `cocoa_gl_fit_layer` 每帧校正到跳动的 bounds。
开机动画能显示是因为震荡从 SystemUI 接管 scanout 后才全面爆发。

### 修复

**布局单一管理权**：嵌入模式下 QEMU 的 `resizeWindow` 不再改 bounds
（frame 的唯一管理者是 player 的 fitGuestView），只触发 relayout 让 EGL
surface 跟随；ANGLE layer 的铺满由 `cocoa_gl_fit_layer` 每帧按当前 bounds
校正（它本来就是这个职责，注释里"视图 bounds 必须等于像素数"的前提已被
fit_layer 取代）。

### 验证（virgl + 冷启动）

```
客机渲染器：GLES: Mesa, virgl (ANGLE (Apple M2 Pro, OpenGL 4.1 Metal))
锁屏大时钟 07:47 与真实时间一致；滑动解锁画面实时跟随
主循环 30fps 稳定；resized 只在真实布局变化时发生
```

### 工程化

`third_party/cocoa.m`（最终版全文）入库：v07 的 cocoa 段上下文与原始树
漂移，diff 补丁无法保证幂等，文件覆盖永远可复现。`third_party/README.md`
更新两步补丁流程（v07 → 覆盖 cocoa.m）。计数器（cocoa_count）通用化为
任意事件名，`resized` 只在真正重建时计数。
