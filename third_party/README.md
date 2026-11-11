# third_party — 第三方源码（不入库）

本目录不入 git（1.8 GB）。复现嵌入引擎的步骤见 `docs/08-embed-single-window.md` E14：

```bash
cd third_party
curl -fLO https://download.qemu.org/qemu-10.1.2.tar.xz
tar xf qemu-10.1.2.tar.xz
curl -fLO https://raw.githubusercontent.com/startergo/homebrew-qemu-virgl/refs/heads/master/Patches/qemu-v07.diff
cd qemu-10.1.2 && patch -p1 < ../qemu-v07.diff
# 嵌入补丁（host view / surface 重建 / 视口 / 绝对指针）已直接改在源码树里，
# 对应文件: ui/cocoa.m；随后按 app/build.sh 的说明构建 libandropod-qemu.dylib
```

`qemu-v07.diff`：startergo/homebrew-qemu-virgl 的 cocoa GL 补丁（上游 QEMU 的
cocoa 显示层没有 OpenGL 支持，`-display cocoa,gl=es` 依赖它）。
