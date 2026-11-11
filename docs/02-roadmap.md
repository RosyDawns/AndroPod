# 路线图

## 阶段 0：控制面验证 —— 已完成

目标：证明在 Apple Silicon 上能用 HVF 起虚拟机、能用 QMP 完整控制、快照恢复足够快。

已交付：
- QMP 客户端（Python + Swift 两套）
- 实例编排：创建、启动、查询、快照、恢复、抓帧、停止
- 端到端冒烟测试 `andropod smoke`（12 项断言全通过）
- macOS 原生壳，含 `--self-test`

实测数据见 README。核心结论：**快照恢复 0.36s vs 冷启动 51.7s，比值约 140 倍**。这条路径成立，产品的地基是稳的。

## 阶段 1：跑起安卓 —— 当前最大风险

这一步没有任何捷径，也是整个项目唯一可能推不下去的地方。

### 问题

AOSP 官方只提供 `ranchu` 虚拟板的镜像，那是 Android Emulator 专用 QEMU 才认识的（依赖 goldfish 设备）。把现成镜像丢给原版 QEMU 的 `virt` 板，大概率连 init 都起不来。

而 Android Emulator 本体**不可再分发**，不能作为底座。

### 三条候选

| 路线 | 工作量 | 风险 |
|---|---|---|
| A. 自编 AOSP，适配 `virt` 板（补 device tree、virtio HAL、GPU 驱动） | 大 | 驱动适配深度未知，可能踩进无底洞 |
| B. 找社区已适配原版 QEMU 的 arm64 镜像 | 小 | 更新频率、许可、来源可信度都不可控 |
| C. Linux arm64 VM + Waydroid 容器 | 中 | 无 GPU、应用兼容性差，但最快能出东西 |

建议顺序：**先花一周做 B 的调研**（最省力），同时用 C 做一个能演示的版本，A 只在 B/C 都不成立时才碰。

### 验收标准

- 能进安卓桌面
- 能装 APK 并打开
- 帧率 > 15fps（非游戏场景）
- 冷启动 < 60s

## 阶段 2：可用的产品

- ~~显示通：内嵌 RFB/VNC 客户端~~ **已完成（2026-11-10）**：Swift RFB 客户端（ZRLE/Tight/Raw/CopyRect，QEMU 的 zlib 流跨矩形共享）已接入 GUI，动态场景 32 fps / 382 KB/s（ZRLE），静态桌面几乎零流量；`screendump` 轮询已从显示路径移除，只作 VNC 失败时的回退。详见 `docs/06-performance.md` 第七节
- 输入通：QMP `input-send-event` 触摸（~7ms）与 adb keyevent 已通；**剩余：键鼠映射**
- 多开：实例模板、批量启动、内存配额、后台实例暂停（VNC 端口自动分配已就绪）
- 快照面板：命名、列表、一键回滚
- APK 安装、文件拖拽、剪贴板、截图录屏

## 阶段 3：商业化前必须做的

- 分发：Developer ID 签名 + 公证 + 自建更新通道。**带 hypervisor 权限的 App 无法上架 Mac App Store**，这条不可绕过
- 许可自查：见 `01-license-boundary.md`
- 兼容性攻坚：这是无底洞，需要专门的测试矩阵

## GPU 加速现状（2026-11-10 实测，详见 docs/07-gpu-virgl.md）

Unity/重图形游戏的真正瓶颈在**客户机渲染**，不在显示传输（后者已由 VNC/ZRLE 解决）：

- 原状态：`ANGLE (Vulkan 1.3.0 SwiftShader)`，纯 CPU 光栅化
- **GPU 加速已达成（E7/E10）**：`startergo/qemu-virgl` + `virtio-gpu-gl-pci,blob=on,hostmem=1G,edid=off` + `memory-backend-file share=on`，镜像自带 virtgpu_detect 自动切 Mesa/virgl。实测 `GLES: Mesa, virgl (ANGLE (Apple M2 Pro, OpenGL 4.1 Metal))`——**客户机跑在宿主 Apple GPU 上**，AndroPod CLI 全链路已验证（E10，锁屏/桌面正常）
- 三个必需 QEMU 开关：`blob=on`（默认关！）、`hostmem`、`share=on` backend；`edid=off` 是稳定性的关键（EDID 多模式集会触发 SF frame-rate 投票 LOG(FATAL) 死循环，E6→E7）
- **客户机侧前置**：GRUB 需 `androidboot.selinux=permissive`（宿主安全策略不允许自动改，留用户/上游 grubenv 开关）；enforcing 下 udmabuf avc denied 影响面待重验
- **三条 QEMU 硬限制**（E10）：virgl 必须 `-display cocoa,gl=es`（无 egl-headless）；`-vnc` 与 GL 互斥；QMP screendump 抓不到 GL 内容（黑帧）→ virgl 实例显示 = QEMU 窗口，GUI 内嵌画面暂不可用
- venus（Vulkan）路径需要 crosvm 或 patched QEMU，当前只有 virgl（GL）；Unity 游戏多数可用 GLES 跑
- 镜像上游：Camgobeg/android-lineage-qemu（有 recovery-userdebug、Magisk、GSI 路径），官方 LineageOS Wiki 已收录 UTM on Apple Silicon
- 结论维持：**不自研 GPU 栈**；剩余工作 = enforcing sepolicy 验证、GUI virgl 画面通路、GL 性能基准与 Unity 实测

## 明确不做的事

- 不做 x86 安卓镜像的软件模拟（性能不可用）
- 不追求跑重度 3D 游戏（这是 MuMu Pro 的战场，正面打没有胜算）
- 不预装 GMS

## 人员配比参考

到「能发布」：4~6 人，12~18 个月。

- 虚拟化/内核 1~2
- 图形 1~2
- macOS 前端 1
- 系统镜像 1

一到两人做，天花板是技术 demo。
