# third_party — 第三方源码（不入库）

本目录（除下面列出的文件）不入 git，约 1.8 GB。复现嵌入引擎的步骤见
`docs/08-embed-single-window.md` 与 `app/build.sh` 头部说明：

```bash
cd third_party
curl -fLO https://download.qemu.org/qemu-10.1.2.tar.xz
tar xf qemu-10.1.2.tar.xz
# 1) 社区 virgl 补丁（audio/coreaudio/virtio-gpu/cocoa GL 支持）
curl -fLO https://raw.githubusercontent.com/startergo/homebrew-qemu-virgl/refs/heads/master/Patches/qemu-v07.diff
cd qemu-10.1.2 && patch -p1 --forward < ../qemu-v07.diff
# 2) AndroPod 嵌入补丁：直接用本目录入库的 cocoa.m 覆盖
#    （host view 挂载、surface 按视图重建、视口校准、绝对指针、
#     布局单一管理、显示调试计数器——git log 可见逐条说明）
cp ../cocoa.m ui/cocoa.m
# 3) 构建：engine/embed/build_libqemu.sh
```

## 入库文件

- `qemu-v07.diff`：startergo/homebrew-qemu-virgl 的补丁（上游 QEMU 的 cocoa
  显示层没有 OpenGL 支持，`-display cocoa,gl=es` 依赖它）。
- `cocoa.m`：QEMU 10.1.2 + v07 之上全部 AndroPod 修改的最终版。以文件覆盖
  方式入库而非 diff 补丁——v07 的 cocoa 段上下文与原始树存在漂移，diff
  无法保证幂等应用；覆盖永远可复现。
