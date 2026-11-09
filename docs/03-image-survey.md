# 安卓镜像调研（阶段 1 前置）

问题：**有没有现成的、能在原版 QEMU 的 `virt` 板上跑起来的 Android arm64 镜像？**

结论：**有，且只有一个可信来源。** 其余候选都因具体原因不可行，原因如下。

## 候选清单与判定

| 候选 | 判定 | 原因 |
|---|---|---|
| Android Emulator 官方镜像（`system-images;android-34;default;arm64-v8a`） | 不可行 | 只为 `ranchu` 虚拟板构建，依赖 goldfish 设备。原版 QEMU 没有这些设备，起不了显示和 GPU。另外 Emulator 本体不可再分发 |
| Cuttlefish 镜像（`aosp_cf_arm64_phone`） | 不可行 | 内核能起，但 Android 会卡在等宿主服务：`secure_env`（keymint/gatekeeper）、`config_server`、logcat/tombstone 接收器依赖 virtconsole/vsock，都由 `launch_cvd` 提供。`launch_cvd` 是 Linux 专属（要 kvm、vhost-vsock、cvdnetwork 组），macOS 上跑不了 |
| Android-x86 / Bliss OS | 不可行 | x86 guest 用不了 HVF，只能 TCG 软件模拟，启动要几分钟且不可用 |
| GSI（Generic System Image） | 不可行 | 设计给 Treble 兼容的真机，不能单独引导，需要一套能跑起来的 vendor/boot |
| 树莓派等设备版 LineageOS | 不可行 | 设备专用 kernel + DTB，`virt` 板没有对应硬件 |
| Waydroid / Redroid | 可行但绕路 | 是 Linux 容器方案，不是虚拟机。要先起一个 ARM64 Linux VM，再在里面跑容器。见 `02-roadmap.md` 路线 C |
| **jqssun/android-lineage-qemu** | **可行** | 专门为 QEMU `virt` 板构建的 LineageOS，见下 |

## 选中的方案

仓库：`https://github.com/jqssun/android-lineage-qemu`

- **LineageOS 23.2（Android 16）**，`arm64only` 与 `x86_64` 双架构
- 发布物是 UTM 虚拟机包：`UTM-VM-lineage-*-virtio_arm64only.zip`，内含 `LineageOS_on_*.utm/Data/{efi_vars.fd, vda.qcow2, vdb.qcow2}`
- 官方文档给出的 macOS 命令与我们环境完全吻合：

```
qemu-system-aarch64 -machine virt -accel hvf \
  -drive if=pflash,unit=0,file=$VMF_CODE,file.locking=off,format=raw,readonly=on \
  -device virtio-blk-pci,drive=vda,bootindex=0 \
  -device virtio-blk-pci,drive=vdb,bootindex=1 \
  -device virtio-gpu-pci -display cocoa \
  -netdev user,id=net0,hostfwd=tcp:0.0.0.0:5555-:5555,hostfwd=tcp:0.0.0.0:5554-:5554
```

即：EDK2 UEFI 引导 + virtio-blk/gpu/net，跟我们 Homebrew QEMU 的能力边界完全对得上。

### 为什么它比 Cuttlefish 靠谱

Cuttlefish 的镜像假设「宿主有配套守护进程」，这个假设在 macOS 上不成立。这个项目绕开了整条宿主依赖：Android 直接在 QEMU 里引导，ADB 走 user-mode 网络的端口转发（5555 adbd / 5554 fastbootd），不需要 vsock、不需要 `launch_cvd`。

### 验收过的事实（本机实测）

见 `04-lineage-bringup.md`。

## 需要接受的代价

1. **没有 3D 加速。** Homebrew 的 QEMU 不带 virglrenderer，只有 2D `virtio-gpu-pci`。
   - `qemu-system-aarch64 -display help` → 只有 `none / curses / cocoa / dbus`，连 VNC 都没有
   - `-device help` 里没有 `virtio-gpu-gl-pci`
   - 结论：GLES 走 SwiftShader 软件渲染。2D 应用、办公、多账号运营够用；重度游戏不行
2. **没有 GMS。** 需要 MindTheGapps（ARM64 版），并且要先进 recovery 绕过签名校验。
3. **社区构建。** 不是 Google 官方产物。可用 `gh attestation verify *.zip -R jqssun/android-lineage-qemu` 核验来源，下载后应比对 release 页给出的 sha256。
4. **多开要先做 overlay。** 基础盘 ~1GB，直接复制不现实。我们的做法是每实例一个 qcow2 overlay 挂在只读基础盘上。

## 备选与升级路径

如果后续必须拿到 3D 加速，两条路：

- **换 QEMU 构建**：`brew install startergo/qemu-virgl-kosmickrisp/qemu` 可拿到带 virgl 的 QEMU，配 `-device virtio-gpu-gl-pci` + GL 显示后端。但这会引入非官方二进制，分发和许可要重新评估
- **换底座**：改用 Apple `Virtualization.framework` 自研 VMM，绕开 QEMU 的图形限制。工作量大，但许可最干净

如果这个镜像的兼容性不够（部分 App 检测 LineageOS），唯一的正解仍然是自己编 AOSP 适配 `virt` 板——那是阶段 1B 的事。
