#!/bin/zsh
# 构建 AndroPod 模拟器桌面 APK（无 gradle：aapt2 + javac + d8 + apksigner）。
# 产物：runtime/images/extra-apks/andropod-home.apk（provision 自动预装）。
set -e

SDK="$HOME/Library/Android/sdk"
BT="$SDK/build-tools/36.0.0"
PLATFORM="$SDK/platforms/android-36.1/android.jar"
HERE="$HOME/AndroPod/app/home-apk"
OUT="$HERE/out"
PRODUCT="$HOME/AndroPod/runtime/images/extra-apks"

rm -rf "$OUT"
mkdir -p "$OUT/gen" "$OUT/classes" "$PRODUCT"

# 1) 资源 + manifest
"$BT/aapt2" compile --dir "$HERE/res" -o "$OUT/res.zip"
"$BT/aapt2" link -o "$OUT/base.apk" \
    -I "$PLATFORM" \
    --manifest "$HERE/AndroidManifest.xml" \
    --java "$OUT/gen" \
    "$OUT/res.zip"

# 2) 编译
"$BT"/d8 --version >/dev/null 2>&1 || true
javac -source 17 -target 17 -classpath "$PLATFORM" \
    -d "$OUT/classes" \
    "$OUT/gen/com/andropod/home/R.java" \
    "$HERE/java/com/andropod/home/MainActivity.java" 2>&1 | grep -v "^Note:" || true

# 3) dex
"$BT/d8" --release --min-api 31 --lib "$PLATFORM" \
    --output "$OUT" $(find "$OUT/classes" -name "*.class")

# 4) 打包 + 对齐 + 签名（zip 的原地更新会被安全中心拦，用 python 合并成新文件）
python3 - "$OUT/base.apk" "$OUT/classes.dex" "$OUT/unsigned.apk" <<'PY'
import sys, zipfile
src, dex, dst = sys.argv[1], sys.argv[2], sys.argv[3]
with zipfile.ZipFile(src) as zin, zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as zout:
    for item in zin.infolist():
        zout.writestr(item, zin.read(item.filename))
    zout.write(dex, "classes.dex")
print("merged", dst)
PY
"$BT/zipalign" -f 4 "$OUT/unsigned.apk" "$OUT/aligned.apk"

KEYSTORE="$HERE/debug.keystore"
if [ ! -f "$KEYSTORE" ]; then
    keytool -genkeypair -keystore "$KEYSTORE" -storepass andropod \
        -alias andropod -keypass andropod -keyalg RSA -keysize 2048 \
        -validity 10950 -dname "CN=AndroPod" >/dev/null 2>&1
fi
"$BT/apksigner" sign --ks "$KEYSTORE" --ks-pass pass:andropod \
    --key-pass pass:andropod --out "$PRODUCT/andropod-home.apk" "$OUT/aligned.apk"

echo "已生成 $PRODUCT/andropod-home.apk ($(du -h "$PRODUCT/andropod-home.apk" | cut -f1))"
