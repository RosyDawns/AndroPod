# 性能：三个数量级的差距在哪

这份文档记录一次「为什么卡」的完整排查。结论是：**卡的原因不在 Android，而在我们自己的三条通路。**

## 一、抓帧：PNG 是灾难

最初的实现在 QEMU 里生成 PNG：

| 格式 | 耗时 | 文件 |
|---|---|---|
| PNG | **129 ms** | 342 KB |
| PPM（原始 RGB） | **6.2 ms** | 3000 KB |

21 倍差距。原因是 PNG 的 deflate 压缩是纯 CPU 的，而它**跑在 QEMU 的主循环里**——每抓一帧就把 vCPU 执行挡住 129 ms。GUI 每秒抓 8 次，等于让客户机丢掉了接近一半的执行时间。

客人看到的「卡」，一大半是我们自己造的。

修正：`screendump` 不传 `format` 参数（QEMU 默认写 PPM），文件后缀也必须是 `.ppm`。3000 KB 看着大，但走页缓存，读它比压缩 342 KB 快得多。

## 二、解码：不要用 ImageIO

`NSImage(data:)` 会走格式嗅探 + 解码。对 3 MB 原始 RGB 毫无必要。

改成一个手写的 P6 解析器（`PPMDecoder`）：mmap 文件、按 PPM 规范跳过空白和注释、拿到 `width/height/offset`，然后交给 vImage 转 BGRA。

| 解码方式 | 耗时 |
|---|---|
| ImageIO（`NSImage(data:)`） | ~20 ms |
| vImage + CGImage | **0.5 ms** |

踩到一个坑：`vImageConvert_RGB888toBGRA8888` **没有 permuteMap 参数**。头文件里第三个参数是 `Pixel_8 alpha`（alpha 填充值），第五个才是 `premultiply`。想当然按「四通道重排」去传会编译失败。

调完这两条，端到端从 ~150 ms/帧（6.7 fps）变成 **7 ms/帧（143 fps 上限）**。

另有一个非性能但影响观感的调整：`Image` 的 `interpolation` 从 `.high` 降到 `.medium`。前者每帧都要对 1280×800 位图做高质量重采样，只为缩小到窗口尺寸，代价不值得。

## 三、输入：一次点击曾经要 30 秒

这是最严重的一条。GUI 的点击走的是 `./bin/andropod tap ...`，也就是**每次点击启动一个 Python 进程**。

实测：

```
real 0.41
real 30.54
real 30.74
```

因为 `input.py` 里 adb 调用的默认 `subprocess.run(timeout=30)`。设备一旦处于不响应状态，每点一下就是 30 秒。

两处修正：

1. **adb 超时 30 s → 2~3 s**，`adb_ready` 探测失败就立刻回退，不要等。
2. **GUI 不再起进程**，改为在应用内直接发指令。

### 界面走哪条路

给 QEMU 加了第三条 QMP socket（`qmp-input.sock`），控制/显示/输入互不干扰。

但最终主路径用的是 **adb**，理由是坐标：

- QEMU 的绝对指针把坐标缩放到 0..32767，实测落点和客户机像素**对不上，且偏移量不稳定**（同一次会话里点不同位置，误差不一样）。
- adb 的 `input tap` 直接说客户机像素，且 `input keyevent 3/4/187` 能发 HOME / BACK / 多任务——这三个键 **QEMU 的 HID 键盘根本没有**（Consumer Control 的 `ac_back` 也不被 Android 识别，实测无效）。

### 持久 shell

`adb -s ... shell input tap x y` 每次冷启动要 140–170 ms，几乎全花在 adb 客户端进程启动上。

改成保持一个交互式 `adb shell` 常驻，往里写命令行：

| 方式 | 延迟 |
|---|---|
| 每次起进程 | 140–170 ms |
| **持久 shell** | **7 ms** |

## 四、一个被误判的问题：快照恢复不会杀死 adb

中途观察到快照恢复后 `adb shell` 全部超时，当时的结论是「恢复快照必然使 adbd 的宿主机连接失效，所以输入不能依赖 adb」。

**这个结论是错的。** 真实原因是 **adb server daemon 自身状态腐烂**：默认端口 5037 被之前异常退出的 daemon 占住，`lsof` 看不到，新 daemon 连上去后缓存了死连接，于是 `adb devices` 显示 `device` 但所有命令挂起。

换一个干净的 server 端口，`adb shell echo ok` 回到 **0.20 秒**。

所以在产品里：

- `ADBShell.prepareServer()` 用专用端口（5599）起自己的 daemon，绝不碰用户的 5037。
- 新端口上设备未注册，所以 `start()` 前必须先 `adb connect`。漏掉这步会让 `get-state` 失败，UI 误判 adb 不可用，静默退回坐标不准的 QMP。

## 五、剩下的硬伤

**渲染器是 SwiftShader。**

```
GLES: Google Inc. (Google), ANGLE (Google, Vulkan 1.3.0
      (SwiftShader Device (LLVM 16.0.0)), SwiftShader driver-5.0.0)
```

纯 CPU 软件渲染。MuMu 流畅的技术基础是它有完整的 GPU 加速栈（网易自研图形层 + 宿主 GPU），而 Homebrew 的 QEMU 不带 `virglrenderer`：

```
$ qemu-system-aarch64 -device help | grep virgl
（无输出）
```

这是架构级差距，靠调参补不回来。能做的只有：

- 提高 vCPU 数量（SwiftShader 会多线程渲染）
- 降低分辨率（像素量与渲染时间近似线性）

实测客户机在滚动时的画面变化率约 **68 fps**（171 次抓帧中 82 个互不相同），说明轻量界面不慢；重负载图形才会暴露软渲染的瓶颈。

## 数据总表

| 环节 | 改前 | 改后 | 倍数 |
|---|---|---|---|
| 抓帧 | 129 ms（PNG） | 4–7 ms（PPM） | ~20× |
| 解码 | ~20 ms（ImageIO） | 0.5 ms（vImage） | ~40× |
| 端到端显示 | ~150 ms / 6.7 fps | 7 ms / 143 fps 上限 | ~20× |
| 输入 | 30000 ms（CLI） | 7 ms（持久 shell） | ~4000× |
| 开机（快照） | — | 3.1–3.6 s | — |

## 六、GUI 一直崩溃的四个独立原因

调完上面三条通路后界面仍然「打开就消失」。逐个排掉，每一个都独立致命：

### 1. `ADBShell.prepareServer()` 在主线程 `waitUntilExit()`

`adb start-server` 在端口状态不好时会无限挂住。放在 `AppModel.init` 里同步等待，等于启动即冻结——看起来像「Timer 不触发」，实际上是**根本没走到创建 Timer 那一行**。

改为只 `run()` 不等待；`connect()` 同理（`adb connect` 也会卡在死 socket 上）。

### 2. `NSApp.activate(ignoringOtherApps:)` 直接 abort

macOS 14+ 上这个调用会让进程 SIGABRT，且**不打印任何信息**。改用 `NSApp.activate()`，`makeKeyAndOrderFront` 本身已足够。

### 3. `PPMDecoder` 里的双重释放

```swift
let dst = UnsafeMutableRawPointer.allocate(...)
defer { dst.deallocate() }
let owned = Data(bytesNoCopy: dst, deallocator: .custom { p, _ in p.deallocate() })
```

两个 owner 释放同一块内存，解码第一帧就 SIGTRAP。改成 `Data(bytes:count:)` 拷贝一份，多花约 1 ms。

### 4. `JSONSerialization` 抛 ObjC 异常，`try?` 抓不住

诊断输出用 `[String: Any]` 装混合类型交给 `JSONSerialization.data`。一旦某个值不被接受，它抛的是 **NSException 而不是 Swift Error**，`try?` 完全无效，进程直接 SIGTRAP。

改成纯文本拼接。这条也是最难查的：崩溃点看起来与抓帧业务毫不相关。

## 七、Timer 必须在 `.common` 模式

`scheduledTimer` 只注册到 `RunLoop.current` 的 `.default` 模式。这个应用会进入其他模式，于是定时器看起来「完全死掉」——诊断计数一直是 0。

```swift
let timer = Timer(timeInterval: 1.0/30, repeats: true) { ... }
RunLoop.main.add(timer, forMode: .common)   // 不是 scheduledTimer
```

## 八、一个环境问题：项目不能放桌面

项目原先在 `~/Desktop`，而桌面受 TCC 保护。每次重新编译签名都会变，于是每次都重新弹「想访问桌面文件夹」，主线程阻塞在 `open()` 上等待用户点击——`sample` 抓到的栈就是 `loadInstances → open`。

项目已迁到 `~/AndroPod`（桌面留符号链接），彻底绕开。同时用 `defaults write com.andropod.app ApplePersistenceIgnoreState -bool YES` 关掉状态恢复，否则每次强杀后重启都会弹「是否恢复窗口」的模态框，同样卡住启动。

## 九、方案 C：把显示通路换成 VNC / ZRLE

前八节都是在给 `screendump` 这条通路打补丁。它有一个无法靠调参消除的结构性缺陷：**轮询 + 全屏**。哪怕画面一个像素都没变，GUI 也会每 33 ms 让 QEMU 把 1280×800×3 = 3 MB 帧缓冲拷进一个文件，再读回来解码；而 `screendump` 本身跑在 QEMU 主循环里，直接占用客户机的 vCPU 时间。

C 方案换成 QEMU 自带的 VNC 后端：它按 **framebuffer damage** 工作，只推送变化的矩形，并且是服务端主动推，宿主不再需要 60 Hz 轮询。

### 实测：动态场景带宽

客户机持续滑动（真实 UI 动画）时，`scripts/vnc_bench.py` 测 3 秒：

| 编码 | 带宽 | 帧率 | 每帧 | 矩形数 |
|---|---|---|---|---|
| Raw | 2196 KB/s | 32.0 fps | 69 KB | 1348 |
| Hextile | 1523 KB/s | — | — | — |
| **ZRLE** | **382 KB/s** | 31.6 fps | 12 KB | 1325 |
| Tight | 331 KB/s | — | — | — |

对照 `screendump`：30 fps × 3 MB ≈ **90 000 KB/s**（不管画面变不变）。

差距约 **230 倍**。而且帧率不是被压缩换来的：ZRLE 仍有 31.6 fps，与 Raw 的 32.0 fps 几乎相同。关键不在压缩算法，而在「只传变化区域」和「推模式」。

静态桌面下 ZRLE 只有约 2 KB/s；GUI 端到端验证中，输入停止后 4 秒内 393 帧总共只累计 545 KB，fps 自然掉到 3.0（只有时钟在变）。**空闲设备几乎不再消耗 CPU 和带宽**，这是 MuMu 那类商业模拟器的基本手感来源。

### 三个必须实测、不能靠猜的协议细节

写 Swift 客户端前用 Python 参考实现（`scripts/zrle_reference.py`）把算法验证到与 `screendump` 逐像素一致，过程中踩到三个坑：

1. **zlib 流是跨矩形、跨帧共享的。** QEMU 对每个 ZRLE 矩形做一次 `Z_SYNC_FLUSH`，但用的是连接级的一条 deflate 流。单独对每个矩形 `zlib.decompress()` 会报 `incomplete or truncated stream`。客户端必须为整条连接保持一个 `z_stream`，只在 `DesktopSize`（分辨率变化）时重建。参考实现里 `decompressobj()` 持续复用后，1340471 字节完整消费。

2. **3 字节 CPIXEL 是 B,G,R，不是 R,G,B。** bpp=32 / depth=24 / max=255 / true-colour 时，RFB 允许去掉 padding 字节，只留 3 字节。我们设 `blue-shift=0`，所以留下的是低三字节，即内存序 B,G,R，**直接拷进 BGRA 前三位即可**。一开始按「通道值 R,G,B」处理，704 个采样点只对上 4 个，且首个像素恰好是 R/B 互换；改成直接拷贝后 **704/704 全部匹配**。

3. **QEMU 采用客户端声明的第一个编码。** 声明顺序 `[ZRLE, CopyRect, Raw, DesktopSize]` → 收到的全是 ZRLE；换成 `[Raw, ...]` → 全是 Raw。所以 ZRLE 必须排在 `SetEncodings` 首位，否则压缩白做。

另外 `-display none` 与 `-vnc` 可以同时启用（QEMU 11 实测），`-vnc 127.0.0.1:N` 监听的是 `5900 + N`，不是端口 N。

### 落地结构

- `engine/andropod/config.py` 增加 `vnc_display`；`vm.py` 生成 `-vnc 127.0.0.1:N,lossy=on`；`cli.py create` 自动分配未被占用的 display（`--no-vnc` 可关，`--vnc-display N` 可指定）。
- `app/Sources/AndroPodCore/VNCClient.swift`：原生 RFB 3.8 客户端，只依赖系统 zlib（SDK 自带 modulemap，自动 link `z`），不引入第三方库。支持 ZRLE（Raw/Solid/PackedPalette/PlainRLE/PaletteRLE 五种 tile 子编码）、Raw、CopyRect、DesktopSize；维护 BGRA framebuffer，增量合成后生成 `CGImage`。
- `AppModel` **双通路并存**：VNC 握手前保留 `screendump` 保证窗口不空白；收到第一帧真实 RFB 画面后永久停掉 poller；VNC 端口未就绪时最多重试 3 次（每次 `refresh` 2.5 s），仍失败则稳定回退并标注 `screendump（VNC 不可用）`。
- 输入路径不变（仍是 QMP 直连 / 常驻 adb shell），VNC 只负责显示，职责单一。

`refresh()` 每 2.5 s 会重跑显示初始化，所以「VNC 接管后不得重建 poller」必须显式判断 `vncReady`——否则会悄悄回到 3 MB/帧 的老路。诊断输出 `/tmp/andropod-gui.txt` 会打印 `displayMode`、`vncReady`、`vncClients` 与矩形编码分布，headless 也能确认走的是哪条路。

### 验证结果

| 验证 | 结果 |
|---|---|
| Python 参考解码 vs `screendump` | **704/704 像素一致** |
| Swift 客户端静态帧 | 1280×800，画面与参考实现一致 |
| Swift 客户端动态 40 帧 | 32.2 fps，109 个 ZRLE 矩形，0.59 ms/帧构建，无解码错误 |
| GUI 端到端（动态） | `displayMode=VNC / ZRLE`，32.2 fps，200 帧，0.22 ms/帧，且诊断中无 `poller.lineage` |
| GUI 端到端（静止） | fps 3.0，393 帧累计仅 545 KB |
| `AndroPod --self-test` | VNC + screendump 两条通路均 PASS |

复现命令：

```bash
./bin/andropod boot --name lineage --snapshot clean
python3 scripts/vnc_bench.py --seconds 3 --encodings raw,zrle,hextile,tight
python3 scripts/zrle_reference.py 24 3          # 逐像素校验
swiftc -O -parse-as-library -o /tmp/vncverify \
  app/Sources/AndroPodCore/VNCClient.swift scripts/VNCVerify.swift
/tmp/vncverify 5901 /tmp/frame.png 40          # 需另开一个连接注入滑动
ANDROPOD_ROOT="$PWD" app/.build/release/AndroPod --self-test
```

### 边界：这不等于能流畅玩 Unity 游戏

C 方案优化的是**画面从客户机搬到宿主窗口**这一段，输入延迟和显示带宽都降下来了，但**客户机内部怎么把一帧画出来没有变**。渲染器仍是 SwiftShader 纯 CPU 软渲染：Unity 这类重图形负载的瓶颈在 Guest 的 GL 调用与合成，VNC 无法加速它。

所以「玩 Unity 游戏」还差方案 A：让镜像支持 virgl / 宿主 GPU。此前实测 `qemu-virgl` 已装好、`virtio-gpu-gl-pci` 与 `cocoa,gl=es` 可用，但当前 LineageOS 镜像是按 2D `virtio-gpu-pci` 配套编译的，`ro.hardware.egl=angle`，且 `surfaceflinger` 因 `avc: denied { read write } name="udmabuf"` 反复重启导致 boot loop。要继续往下走，需要改镜像的 SELinux 策略与 EGL HAL，或换 Cuttlefish 方案。这属于下一阶段，不是调参能绕过的。
