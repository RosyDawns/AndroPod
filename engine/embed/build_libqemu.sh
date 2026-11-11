#!/bin/bash
# 把已构建的 QEMU 对象文件重新链接成动态库，供 GUI 进程内加载。
# 用法：engine/embed/build_libqemu.sh
set -euo pipefail

BUILD="${BUILD:-$HOME/AndroPod/third_party/qemu-10.1.2/build}"
OUT="${OUT:-$HOME/AndroPod/engine/embed}"
QEMU_BIN="qemu-system-aarch64"

[ -f "$BUILD/$QEMU_BIN" ] || { echo "先构建 QEMU: $BUILD/$QEMU_BIN 不存在" >&2; exit 1; }

clang -O2 -c "$OUT/andropod_qemu.c" -o "$OUT/andropod_qemu.o"

LINK_CMD="$(cd "$BUILD" && ninja -t commands "$QEMU_BIN" | tail -2 | head -1)"

python3 - "$LINK_CMD" "$BUILD" "$OUT" <<'PY'
import shlex, subprocess, sys

cmd, build, out = sys.argv[1], sys.argv[2], sys.argv[3]
toks = shlex.split(cmd)
assert toks[0] in ("cc", "clang"), toks[:2]

toks = toks[1:]
# 去掉 -o <binary>
i = toks.index("-o")
del toks[i:i + 2]
# 导出符号表是给插件用的，会隐藏 qemu_init 等；动态库要全量导出
toks = [t for t in toks if not t.startswith("-Wl,-exported_symbols_list")]
# 去掉自带 main() 的目标文件，避免和宿主进程的 main 打架
toks = [t for t in toks if not t.endswith("system_main.c.o")]

new = ["clang", "-dynamiclib", "-install_name", "@rpath/libandropod-qemu.dylib",
       "-o", f"{out}/libandropod-qemu.dylib"] + toks + [f"{out}/andropod_qemu.o"]

print(f"[build] linking {len(toks)} objects -> libandropod-qemu.dylib")
subprocess.run(new, cwd=build, check=True)
PY

echo "[build] done:"
ls -lh "$OUT/libandropod-qemu.dylib"
nm -gU "$OUT/libandropod-qemu.dylib" | grep -E " _andropod_qemu_start| _qemu_init| _qemu_main_loop| _qemu_cleanup" | head
