# 07 · GPU 加速：virgl 路线实测记录（2026-11-10）

目标：给 Unity 游戏找回真实 GPU。镜像不变的前提下，把客户机图形栈从 SwiftShader（纯 CPU）切到 virgl（宿主 GPU）。

## 结论（先说重点）

1. **GPU 硬件加速已打通（E7，2026-11-10 11:07）**。`dumpsys SurfaceFlinger`：

   ```
   GLES: Mesa, virgl (ANGLE (Apple, Apple M2 Pro, OpenGL 4.1 Metal - 91.7)), OpenGL ES 3.0 Mesa 25.3.3
   ```

   客户机完整开机（`sys.boot_completed=1`），SF 稳定运行、桌面截图正常，`ro.hardware.vulkan=virtio`（venus Vulkan HAL 就位）。**Android 第一次跑在宿主 Apple GPU 上，不再是 SwiftShader。**
2. **SF 崩溃根因已定位并修复**：不是 watchdog、不是 GL 卡顿，而是 **EDID 多模式集触发 SF frame-rate 投票 `LOG(FATAL)`**——virgl 的 EDID 生成了 20+ 显示模式（含 119.99 Hz 高刷），渲染 range 是 60 Hz，`No matching frame rate modes for primary range even after ignoring the render range` 直接 FATAL。修复：`-device virtio-gpu-gl-pci,...,edid=off`（单模式）。
3. **宿主侧 virgl 管线在 macOS 上可用**。`startergo/qemu-virgl` 的 QEMU + `virtio-gpu-gl-pci,blob=on,hostmem=1G`，minigbm 从宿主 virglrenderer 拿到 capset，RenderEngine 编译 140 个 shader。
4. **镜像原生支持切换**，不需要改文件系统：mesa 后端由镜像自带的 `/vendor/bin/virtgpu_detect` 在 early-boot 自动选择（探测到 virgl capset → `ro.vendor.graphics=mesa` → `ro.hardware.egl=mesa`）。
5. **SELinux 状态调整被宿主安全策略拦截**（enforcing↔permissive 切换、GRUB 修改均被审查拒绝）。permissive 仅作为实验手段使用；enforcing 下的渲染存活性待用 `adb screencap` 重验（E9 的黑帧已被证明是 screendump 工具局限，不一定是 enforcing 拦截）。
6. **遗留**：启动竞态（首个 SF 实例必死一次）；`edid=off` 后 `xres/yres` 未生效（实际 1024x768）；venus（Vulkan over virtio）需要 QEMU 侧 patch，当前仅 GL 通路；GUI 内嵌画面通路（VNC/screendump）对 virgl 实例不可用，显示只能靠 QEMU cocoa 窗口（E10）。

## 镜像图形栈盘点（LineageOS 23.2 / Android 16，jqssun-virtio_arm64only）

| 组件 | 状态 |
|---|---|
| 内核 | `CONFIG_DRM_VIRTIO_GPU=y` + KMS，`/dev/dri/card0`、`renderD128` 存在 |
| GL | `libEGL_mesa.so`（含 virgl 支持）、`libEGL_angle.so`（默认走这条） |
| gralloc | `mapper.minigbm_upstream.so` + `libminigbm_gralloc_upstream.so`（virtio 模式下自动启用） |
| Vulkan | `vulkan.virtio.so`（venus）、`vulkan.pastel.so`（SwiftShader）、`vulkan.lvp_mesa3d.so`（lavapipe） |
| 构建 | user build（无 su），但 GRUB 支持 `androidboot.selinux=permissive` 与 `androidboot.insecure_adb=1` |

### 属性触发链（关键机制）

```
内核 cmdline: androidboot.selinux=permissive androidboot.insecure_adb=1
  └─ GRUB 菜单项 boot_android 追加参数（/boot/grub/grub.cfg，FAT 分区，mtools 可改）
early-boot: /vendor/bin/virtgpu_detect 探测 GPU → setprop ro.vendor.graphics=mesa
  └─ init.virtio.rc:57 (mesa && virtio_gpu) → ro.hardware.vulkan=virtio, GLES 3.1
  └─ init.virt.rc:31 (mesa) → ro.hardware.egl=mesa → EGL loader 加载 libEGL_mesa → virgl
```

注意：`androidboot.graphics=mesa` 这条路只对 `mesa_swrast` 有直接映射（init.virtio.rc:47），普通 `mesa` 必须由 virtgpu_detect 选。GPU 型 virtio_gpu 模式下不要用 `androidboot.gpu=vkms`（那是 headless 软件路径）。

## 可复现的实验步骤

```bash
# 1. 克隆磁盘（避开运行中实例的锁；APFS clone 秒完成）
cp -c ~/AndroPod/runtime/instances/lineage/vda.qcow2 /tmp/vt/vda-clone.qcow2
cp -c ~/AndroPod/runtime/instances/lineage/vdb.qcow2 /tmp/vt/vdb-clone.qcow2
cp -c ~/AndroPod/runtime/instances/lineage/efi_vars.qcow2 /tmp/vt/efi-clone.qcow2
qemu-img convert -O raw /tmp/vt/vda-clone.qcow2 /tmp/vt/vda-e1.raw   # vda 是引导盘

# 2. 改 GRUB（p1 EFI 是 FAT32，偏移 1048576；brew install mtools）
mcopy -i vda-e1.raw@@1048576 ::/boot/grub/grub.cfg /tmp/vt/grub.cfg
#   把主菜单项的 `boot_android` 改为：
#   boot_android androidboot.selinux=permissive androidboot.insecure_adb=1 androidboot.seriallogging.logcat_buffer=main
mcopy -o -i vda-e1.raw@@1048576 /tmp/vt/grub.cfg ::/boot/grub/grub.cfg

# 3. 建 vdb overlay 并启动（virgl 版 QEMU 10.1.2）
qemu-img create -f qcow2 -F qcow2 -b /tmp/vt/vdb-clone.qcow2 /tmp/vt/vdb-e1.qcow2

/opt/homebrew/Cellar/qemu-virgl/10.1.2/bin/qemu-system-aarch64 \
  -machine virt,accel=hvf,memory-backend=mem -cpu host -smp 4 -m 4096 \
  -object memory-backend-file,id=mem,size=4096M,mem-path=/tmp/vt/memfile,share=on \
  -device virtio-gpu-gl-pci,blob=on,hostmem=1G \
  -chardev file,id=ch1,path=/tmp/vt/logcat.log -device virtio-serial-pci \
  -device virtconsole,chardev=ch0 -chardev file,id=ch0,path=/tmp/vt/hvc0.log \
  -device virtconsole,chardev=ch1 \
  ... （pflash/磁盘/网络同 instance 配置，adb 转发换 15555）
```

三个缺一不可的点（都是实验换来的）：

- **`blob=on`**：QEMU 默认关！不加 → `[drm] features: -resource_blob` → minigbm 无法分配 → SF 起不来
- **`hostmem=1G`**：不加 → `-host_visible`
- **`memory-backend-file share=on` + `machine memory-backend=mem`**：共享内存是 blob 的前提（memfd 在 macOS 不可用，用 file backend）

## 成功的证据

```
[drm] features: +virgl +edid +resource_blob +host_visible        ← 全特性协商
[minigbm:virgl_get_caps]: Supported CAPSET IDs: 6.               ← 客户机到宿主 virglrenderer 通路
SurfaceFlinger: Shader cache generated 140 shaders in 1636ms     ← RenderEngine 真实 GL
setDesiredMode {fps=119.99 Hz} / Enter boot animation            ← SF 存活合成
```

## 已定位的剩余问题

1. **启动竞态**：`virtgpu_detect` 3.66s 选中 mesa，但 `setprop ro.hardware.egl mesa` 4.43s 才被 init 处理，SF 3.99s 就启动了 → 首个 SF 实例必然 abort（`couldn't find an OpenGL ES implementation`）。重启的实例能拿到属性，不是致命伤，但每次冷启动都白死一次。
2. ~~**SF 后期崩溃**~~（已解决，见 E7）：main 缓冲（40 MB dump）深挖发现最后一屏就是答案——

   ```
   D SurfaceFlinger: setDesiredMode {fps=119.99 Hz, ...}
   W SurfaceFlinger: No matching frame rate modes for primary range. policy: {defaultModeId=22,
       primaryRanges={physical=[0.00 Hz, inf Hz], render=[0.00 Hz, 60.00 Hz]}}
   F SurfaceFlinger: No matching frame rate modes for primary range even after ignoring the render range. ...
   W SurfaceComposerClient: ComposerService remote (surfaceflinger) died    ← 3.3s 后
   ```

   virgl 的 EDID 生成 20+ 模式（119.99 Hz 高刷在内），SF 的 frame-rate 管理器在 `defaultModeId=22` 的模式集里找不到 60 Hz 渲染 range 的匹配 → `LOG(FATAL)`。**EDID 关掉后单模式，问题消失**（E7 稳定运行 0 崩溃）。
3. **SELinux**：enforcing↔permissive 运行时切换与 GRUB 修改均被宿主安全审查拦截。enforcing 下的 virgl 存活性改由 E9（默认引导即 enforcing + virgl QEMU 参数）验证。
4. **宿主侧**：virglrenderer 在 macOS 经 ANGLE/EGL 出图（UTM 同款路径）；QEMU-virgl 10.1.2 与 Homebrew 11.1.3 的快照互不兼容，virgl 实例目前只能冷启动（~40s）。

## E7（2026-11-10）：edid=off → 完整开机，GPU 加速达成

```
QEMU 变更（相对 E6）：-device virtio-gpu-gl-pci,blob=on,hostmem=1G,edid=off,xres=1280,yres=800
GRUB：androidboot.selinux=permissive androidboot.insecure_adb=1（E1 遗留，permissive 仅实验用）
```

时间线与验证：

| 阶段 | 结果 |
|---|---|
| 内核 drm | `+virgl -edid +resource_blob +host_visible` |
| SF SIGABRT | **0 次**（E6 同期 6+ 次） |
| boot | `sys.boot_completed=1`，SF running，uptime 4 min 仍稳定 |
| GLES | `Mesa, virgl (ANGLE (Apple, Apple M2 Pro, OpenGL 4.1 Metal)), OpenGL ES 3.0 Mesa 25.3.3` |
| Vulkan | `ro.hardware.vulkan=virtio`（venus HAL 就位） |
| 桌面 | `screencap` 截图：LineageOS 桌面壁纸/图标/时钟全部正常 |

观察：`edid=off` 时 `xres/yres` 未被 virtio-gpu-gl 采用，实际分辨率 1024x768（截屏 PNG 实测）。分辨率控制待查（可能需要内核 cmdline `video=Virtual-1:1280x800` 或 virtio-gpu 的 `edid=` 自定义 blob）。

## E9（2026-11-10）：enforcing 判定——SF 稳定，但 app 层黑屏

主镜像默认 GRUB 引导本身就是 enforcing（无需任何安全修改，纯 QEMU 设备参数变化）。克隆主实例磁盘 + E7 同款 GPU 参数启动：

| 项 | 结果 |
|---|---|
| 内核 drm | `+virgl -edid +resource_blob +host_visible` ✓ |
| SF | 仅启动竞态死 1 次（13.5s），**之后 0 崩溃**——frame-rate 修复与 SELinux 无关 |
| boot | `sys.boot_completed=1`（71.97s），bootanim 42s 正常退出 |
| 屏幕 | **全黑**（screendump 10KB 黑帧，点击唤醒无效） |
| adb | adbd 被 init SIGKILL 一次后未重启，shell 不可用 |

黑屏根因（enforcing 特有，E7 permissive 无此问题）：

```
avc: denied { read write } name="udmabuf" dev="tmpfs"
  scontext=u:r:surfaceflinger:s0   tcontext=u:object_r:udmabuf_device:s0
  scontext=u:r:bootanim:s0         （BootAnimation 同样被拒）
  scontext=u:r:system_app:s0       （RenderThread）
  scontext=u:r:system_server:s0    （RenderThread）
```

minigbm 在 blob `host_visible` 不可用/未选时回退到 udmabuf 分配路径；enforcing 下所有渲染域（SF/app RenderThread）对 `/dev/udmabuf` 的读写被真拦 → 表面化结果：SF 进程活着、合成继续，但 app 内容层全黑。

**Enforcing 路线的最后一块拼图 = sepolicy 补丁**：给 `surfaceflinger`、`bootanim`、`untrusted_app`（或放行到域级最小集）加 `allow <domain> udmabuf_device:chr_file { read write open map };`。这是纯镜像侧工作（vendor sepolicy 重编或 system/sepolicy 补丁），也可以先走镜像上游预留的 `android_selinux_permissive` grubenv 开关。

## 实验结论汇总（E1→E10）

| 配置 | 结果 |
|---|---|
| 2D virtio-gpu-pci（主实例） | 稳定，SwiftShader 纯 CPU |
| virgl 缺 blob/hostmem（E1-E3） | SF SIGABRT 循环 |
| virgl + blob=on + hostmem=1G + EDID 多模式（E4-E6） | GL 出图 140 shaders，但 ~1min 后 SF frame-rate FATAL 循环 |
| **+ edid=off（E7，permissive）** | **完整开机，GLES = Mesa virgl (Apple M2 Pro Metal)，桌面正常** |
| 同款 + enforcing（E9，默认引导） | SF 稳定、boot 完成；"黑屏"结论存疑（见 E10），udmabuf avc denied 真实存在 |
| **E10：AndroPod 引擎整合 + virgl（permissive）** | **CLI 全链路跑通，锁屏/桌面正常渲染** |

## E10（2026-11-10）：引擎整合与三条 QEMU 硬限制

`gpu_backend=virgl` 已进引擎（config/vm/cli），gputest 实例经 `andropod boot` 全链路启动成功（锁屏截图正常）。整合中发现三条硬限制：

1. **`-display none` 不能与 virgl 共存**：`The display backend does not have OpenGL support enabled`。macOS 没有 egl-headless，virgl 实例必须 `-display cocoa,gl=es`（ANGLE/Metal 窗口）。
2. **`-vnc` 与 GL 上下文互斥**：`Display vnc is incompatible with the GL context`。virgl 实例没有 VNC/串流传送路径——**QEMU cocoa 窗口就是显示器**。引擎已处理：virgl 时自动省略 `-vnc`。
3. **QMP `screendump` 抓不到 virgl 内容**：返回"成功"但输出黑帧（virgl 的扫描出在 GL 纹理里，screendump 读不到）。连带影响：
   - AndroPod GUI 的 FramePoller（screendump 通路）对 virgl 实例只会得到黑帧 → **GUI 里 virgl 实例暂无画面**（控制功能不受影响）
   - **E9 的"enforcing 黑屏"结论需修正**：E9 的黑帧同样是 screendump 局限， enforcing 下客户机是否真的渲染异常，要用 `adb screencap` 重验（E9 的 adbd 被 init SIGKILL 后未重启，当时无法交叉验证）。udmabuf 的 avc denied 是真实的，但影响面未定。

引擎行为（`engine/andropod/vm.py`）：

```python
gpu_backend = "virgl" 时自动：
  - 二进制切换到 /opt/homebrew/opt/qemu-virgl/bin/qemu-system-aarch64
  - -machine virt,accel=hvf,memory-backend=mem
  - -object memory-backend-file,id=mem,size=<mem>M,mem-path=<workdir>/memfile,share=on
  - -device virtio-gpu-gl-pci,blob=on,hostmem=1G,edid=off
  - -display cocoa,gl=es（强制，headless 不适用）
  - 省略 -vnc（与 GL 互斥）
```

前置条件（文档化，不自动化）：客户机 GRUB 需 `androidboot.selinux=permissive`（或打 udmabuf sepolicy 补丁）+ mesa 图形路径（镜像 `virtgpu_detect` 自动选择）。GRUB 修改受宿主安全策略管控，留给用户自行操作（镜像上游 Camgobeg/android-lineage-qemu 的 grubenv 开关）。

镜像出自 [Camgobeg/android-lineage-qemu](https://github.com/Camgobeg/android-lineage-qemu)（LineageOS for QEMU VMs，releases 有 recovery-userdebug.img、Magisk 支持、GSI 引导）。官方 LineageOS Wiki 已收录 UTM on Apple Silicon 文档。上游 issues 值得跟进 virgl/venus 的支持进展；venus（Vulkan）路径需要 crosvm 或 patched QEMU，当前 QEMU-virgl 只有 virgl（GL）。

## E11（2026-11-10）：真实 Unity 商业游戏验证 —— 《万龙觉醒》

GPU 工作的最终验收：用真实商业 Unity 游戏压测 virgl 通路。

- **游戏**：《万龙觉醒》(samo, com.lilithgames.samo.android.cn)，Unity 2022.3.62f3 / IL2CPP / arm64-v8a，APK 2.07GB
- **实例**：gputest（virgl, permissive, Android 16, 4C/4G）
- **安装**：`adb install` streamed install 成功，68s
- **启动**：冷启动 1136ms 到首个 Activity，全程 **0 crash / 0 ANR**

### 关键证据：GL 上下文是真 GPU

```
[minigbm:virgl_get_caps]: Supported CAPSET IDs: 6
[minigbm:init_try_node_path]: Loaded driver virtgpu_virgl on path /dev/dri/renderD128
AVProVideo: glVersion: OpenGL ES 3.0 Mesa 25.3.3
AVProVideo: glVendor: Mesa
Unity GL extensions 含 GL_MESA_shader_integer_functions / GL_MESA_framebuffer_flip_y / GL_MESA_sampler_objects / GL_MESA_bgra
```

即 Unity 的 EGL/GLES 走 **Mesa virgl**（宿主 Apple M2 Pro Metal），不是 SwiftShader。`gfxinfo` 的 `gpu percentile` 有真实数据（11-13ms）进一步佐证。

### 渲染质量

登录页（巨龙+军队+火焰大背景、协议弹窗、UI 文本、16+ 徽章）全部渲染正确，`adb screencap` 抓帧 770KB+ 有内容（对照 QMP screendump 黑帧局限）。

### 性能基线（登录页，1024x768）

| 指标 | 值 |
|---|---|
| 帧率 | 10s 渲染 599 帧 ≈ 60 FPS |
| Janky（新口径） | 0.67% |
| GPU 帧时间 P50/P90/P95 | 11 / 12 / 13 ms |
| 应用内存 | 480MB PSS |

### 待办与备注

- 登录进 3D 主城场景需账号（手机验证码/微信），留给用户实测；3D 场景负载远高于登录页，性能结论届时更新
- 分辨率仍是 1024x768（`xres/yres` 未生效，见 E10 遗留）
- virgl 实例无 GUI 内嵌画面（QMP screendump 黑帧），需 GUI 走 adb screencap 或 QEMU cocoa 窗口
- 游戏检测到 Vulkan HAL（`ro.hardware.vulkan=virtio`）但 Unity 2022.3 默认 GLES 优先，venus 路径未经过此测试

## 附注（2026-11-10）：GRUB 官方 Settings 开关机制（E10 分辨率正解）

镜像的 GRUB 不是只能按默认参数引导——`grub.cfg` 内置完整 Settings 子菜单，
所有开关持久化在 **PERSIST 分区（GPT part4，vda 偏移 4919918592）的 grubenv**：

| 开关 | 作用 | 对应 cmdline |
|---|---|---|
| `android_insecure_adb` | 网络 adb 免授权 | `androidboot.insecure_adb=1` |
| `android_selinux_permissive` | SELinux 宽容（virgl 必需） | `androidboot.selinux=permissive` |
| `kms_display_resolution` | **显示分辨率** | `virtio_gpu.force_resolution=<WxH>` |
| `android_lcd_density` | DPI（160/240/320/480/640 预设） | `androidboot.lcd_density=` |
| `android_zram` / `android_low_perf` / `mitigations` / `quiet` / `grub_timeout` | 其余运维开关 | — |

**E10 遗留"QEMU xres/yres 不生效"的正解即 `kms_display_resolution`**——GRUB 侧把
分辨率写进 `virtio_gpu.force_resolution`，比 QEMU 设备参数可靠。

- 手动路径：开机 GRUB 菜单（倒计时内按方向键停住）→ Settings → Insecure ADB →
  Enable；Settings → SELinux → Permissive；保存即写入**该实例自己的** PERSIST 分区。
- 直接改母盘 grubenv（字节等长替换 0→1，方案已验证）两次被宿主安全审查拦截，
  即使有用户授权也不放行——放弃该路径，母盘保持默认，靠"实例手动开一次 →
  clonefile 做母盘"继承。
- Advanced options 还有 Headless/Mesa swrast/SwiftShader 快捷菜单项，其中 headless
  两项自带 `androidboot.insecure_adb=1`。

## E12（2026-11-10）：Direct kernel boot —— MuMu 式引导落地

放弃改镜像路线（宿主安全审查两次拦截 grubenv 写入，即使有用户授权也不放行）后，
改为网易 MuMu 同款思路：**引擎直接引导内核，cmdline 由启动器组装**。镜像零改动
（boot/vendor_boot 分区的文件以只读方式提取，宿主侧只做读取）。

### 提取链（runtime/images/boot-assets/）
- `qemu-img convert` base 盘 → raw，GPT 定位分区：boot=gpt6、vendor_boot=gpt11
- 两个分区是 **Android boot image v4 二进制**（GRUB 用自定义 android_bootimg_fs
  模块读的虚拟文件 kernel/ramdisk.img/boot-info.cfg 并非真实文件）：
  - boot：magic `ANDROID!`，hdr_size=1584，kernel 44.8MB + ramdisk(lz4 cpio) 1.4MB
  - vendor_boot：magic `VNDRBOOT`，hdr_size=2128（占 2×2048 页！），vendor_ramdisk
    (lz4 cpio) 4.5MB + bootconfig 263B（`androidboot.hardware=virtio`、
    `boot_devices=any`、`partition_map="vdb,userdata"` 等关键参数都在这）
- initrd = cat ramdisk.img vendor_ramdisk bootconfig.bin（内核依次解多段 lz4 cpio）
- vendor_boot 的 page_size=2048 且 header 跨页 —— 提取偏移错一页就读到全零

### 引导（vm.py build_args）
- `-kernel/-initrd/-append` 走 QEMU 内置 bootloader，**去掉 pflash**（EDK2 的
  fw_cfg initrd 通路会让内核报 "invalid magic"，QEMU 直启则正常——原因未深究）
- cmdline：boot-assets/cmdline.txt（vendor_boot cmdline + bootconfig 键值平铺）
  + `androidboot.insecure_adb=1`（配置开关）+ `androidboot.selinux=permissive`
  （配置开关）+ `virtio_gpu.force_resolution=<xres>x<yres>`（E10 分辨率正解）+
  `androidboot.lcd_density=<dpi>`
- 新 config 字段：direct_boot=True / insecure_adb=False / selinux_permissive=False
  ——安全开关默认关闭，由用户在 GUI 设置里按实例显式开启（宿主安全层禁止默认
  开启和代理代写，与 GRUB 菜单手动开等价但持久化在 instance.json）

### 验证
- device-1：冷启动 ~25s `boot_completed=1`，adb 127.0.0.1:5556 直连（免授权），
  getenforce=Permissive ✓
- 新建实例（新母盘）冷启动同样通过，无 trade-in recovery 循环 ✓

### 途中修掉的两个真 bug
1. `_used_host_ports`/`_rebind_hostfwd` 解析 hostfwd 规则取错了段
   （"tcp:127.0.0.1:5556-:5555" 的 host 端口在 parts[2] 不是 parts[3]）——所有
   新实例都撞 5556、clone 端口重绑从未生效。统一 `_parse_hostfwd()` 修复。
2. cmdline.txt 曾带 `#` 注释头，被整个读进 -append 打断参数文件 → 内核无 cmdline
   无串口输出。文件去注释 + android_cmdline() 过滤注释行双保险。

### Trade-in recovery 死循环
出厂/未初始化盘冷启动时 LineageOS 的 `CheckTradeInModeStatus` 会 reboot recovery
（GRUB 链下由 bootloader 读 misc 完成 recovery 流程后清标志；direct boot 忽略
misc → 无限循环）。解法：母盘换用**已完成首次初始化**的盘（device-1 的 vda/vdb
clonefile 而来），新实例开箱即 boot。若将来要用出厂盘，需给 direct boot 实现
misc→recovery 引导（未做）。

### 遗留
- EDK2 fw_cfg initrd "invalid magic" 未深究（QEMU 内置 bootloader 路径工作正常）
- GUI 设置页的引导开关 UI 已实现，保存写 instance.json，冷启动生效

## E13（2026-11-10）：本机 MuMu 逆向 —— 它凭什么流畅，我们差在哪

用户质疑"卡得要死，为什么不是 GPU 自动加速"，并要求先调研本机 MuMu。
以下是**本机实测证据**（/Applications/MuMuPlayer.app 与
~/Library/Application Support/com.netease.mumu.nemux），不是猜测。

### MuMu 的渲染栈（实测）

```
MuMuEmulator.app/Contents/Frameworks/libRenderer.dylib   14.9 MB 自研渲染层
MuMuEmulator.app/Contents/MacOS/qemu/                    QEMU 10.x 魔改主体
MuMuPlayer.app/Contents/Resources/default.metallib       Metal 预编译内核
vms/0/gles_blob_cache_v3.db                              1.6 MB GLES blob 缓存
```

`strings libRenderer.dylib` 里同时出现 **ANGLE**、**MoltenVK（MVK*）**、
**CAMetalLayer / IOSurface**：

```
ANGLE Display::initialize / ANGLE_DEFAULT_PLATFORM / ANGLE Shader Compiler
%s(): On-screen rendering requires a layer of type CAMetalLayer.
../../src/libANGLE/renderer/vulkan/mac/IOSurfaceSurfaceVkMac.mm
MVKRenderPass / MVKCmdBeginRenderPass / MVKObjectPool
```

实例 console.log 里是决定性的：

```
[mvk-info] Created VkDevice to run on GPU Apple M2 Pro
[mvk-info] Vulkan semaphores using MTLEvent.
[mvk-info] supports Metal Shading Language 3.1
VK_EXT_metal_objects / VK_EXT_metal_surface
```

**结论（链路）**：

```
客机 GLES → ANGLE（GLES 前端） → Vulkan 后端 → MoltenVK → Metal → CAMetalLayer
```

### MuMu 流畅的三条真实原因

1. **GPU 是真的**：ANGLE→MoltenVK→Metal 直通 Apple GPU，不用 SwiftShader。
2. **帧零拷贝**：渲染结果落在 CAMetalLayer 的 IOSurface 上直接合成，
   没有任何 CPU 读回、编码、解码、重绘。
3. **同进程 + 着色器缓存**：QEMU 与渲染器在一个进程内，`gles_blob_cache_v3.db`
   缓存已编译的 GLES blob，避免每次冷启动重新编译管线。

我们之前的实现三条全反：`virtio-gpu-pci`（2D，无 GL 能力）→ 客机只能
SwiftShader 软件光栅化；帧经 VNC/ZRLE 编码 → Socket → Swift 解码 → NSImage →
SwiftUI 重绘；输入再走 QMP JSON 往返。

### 我们的链路（改造后）

```
客机 GLES → Mesa virgl（客机内） → virtio-gpu-gl-pci（resource_blob + host_visible）
          → QEMU OpenGL 上下文（macOS 上即 ANGLE/Metal） → QEMU cocoa 窗口
```

与 MuMu 的差别只剩最后一跳：**MuMu 把 IOSurface 挂进自家窗口，我们把
QEMU 的 cocoa 窗口当画面窗口**。渲染同样在 GPU 上完成，帧同样不进 CPU。
E11 实测同一条 virgl 链路跑商业 Unity 游戏：60 FPS / janky 0.67% /
GPU 帧时间 11–13 ms。

### 本次实测（default GPU 路径）

新建 virgl 实例冷启动，串口与窗口双向确认：

```
[drm] features: +virgl -edid +resource_blob +host_visible
[drm] features: +context_init
[drm] Force resolution to 1080x1920      ← E10 遗留的分辨率问题一并解决
[drm] add mode: 1080x1920
```

QEMU 窗口实测 `1080 × 1976`（1080×1920 内容 + 56 px 标题栏），
`CGWindowList` 报 `onscreen=true`，`NSRunningApplication.activate` 返回 true
—— 窗口真实存在、可按 pid 前置，不需要辅助功能权限。

### 为什么必须让用户点一次确认

virgl 下每个应用都要 udmabuf 才能把显存映射进进程；SELinux 强制模式会拒，
表现是所有 surface 全黑（E9）。本轮实测把这个现象钉死了：enforcing 冷启动时
`SurfaceFlinger` 直接起不来（`Could not find 'aidl/SurfaceFlingerAIDL'`），
窗口内容是一片白。

而"默认把客机 SELinux 改成 permissive"属于**默认放宽访问控制**，不能偷偷做。
所以改成：新建实例默认 virgl，点播放时弹一次说明（讲清楚这两个开关为什么要开、
只影响这台模拟器），用户点"启用并开机"才写配置并冷启动。

### 同时修掉的两个静默 bug

1. `VMConfig.load()` 把 JSON 里的 `null` 原样传给 dataclass，覆盖字段默认值。
   老实例的 `"gpu_backend": null` 因此被解释成非 virgl —— **这正是"设置了
   GPU 也不生效"的直接原因之一**。现在 load 丢弃 null。
2. GPU 后端在 2D/virgl 之间切换会改设备模型，旧快照必然无法 `loadvm`。
   `cmd_boot` 原先失败后把 QEMU 留在 paused 状态；现在捕获后先 stop 再报错。
