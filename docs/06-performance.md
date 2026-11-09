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
