#!/bin/sh
# Builds AndroPod.app without Xcode. SwiftPM produces the manager binary; the
# player (QEMU embedded as a library), the engine dylib, ANGLE and pc-bios are
# copied in so the bundle is self-contained and one process owns one device.
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT/app"
EMBED="$ROOT/engine/embed"
BUNDLE="$APP_DIR/build/AndroPod.app"
QEMU_BUILD="$ROOT/third_party/qemu-10.1.2/build"

cd "$APP_DIR"
swift build -c release

if [ ! -f "$EMBED/libandropod-qemu.dylib" ]; then
    echo "缺少 $EMBED/libandropod-qemu.dylib" >&2
    echo "先运行: engine/embed/build_libqemu.sh" >&2
    exit 1
fi

# The player is a Mach-O, not a script: it must be compiled against the same
# dylib the manager ships, and signed with the HVF entitlement afterwards.
clang -fobjc-arc -O2 -o "$EMBED/player" "$EMBED/player.m" \
    -framework Cocoa \
    -L"$EMBED" -landropod-qemu \
    -Wl,-rpath,@executable_path/../Frameworks \
    -Wl,-rpath,"$EMBED"

# Refresh in place rather than `rm -rf` the bundle: the signing identity is
# ad-hoc, and a wholesale delete of a few hundred bundled files trips the
# host's bulk-delete guard for no benefit.
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources" \
         "$BUNDLE/Contents/Frameworks"
rm -f "$BUNDLE/Contents/MacOS/AndroPod" \
      "$BUNDLE/Contents/MacOS/andropod-player" \
      "$BUNDLE/Contents/MacOS/libEGL.dylib" \
      "$BUNDLE/Contents/MacOS/libGLESv2.dylib" \
      "$BUNDLE/Contents/Frameworks/libandropod-qemu.dylib"
cp "$APP_DIR/.build/release/AndroPod" "$BUNDLE/Contents/MacOS/AndroPod"

# ANGLE is dlopen'd by the GL display layer, not linked. dyld searches the main
# executable's directory for a bare library name, so these two live next to the
# player rather than in Frameworks.
cp "$EMBED/player" "$BUNDLE/Contents/MacOS/andropod-player"
cp "$EMBED/libandropod-qemu.dylib" "$BUNDLE/Contents/Frameworks/"
cp /opt/homebrew/opt/libangle/lib/libEGL.dylib "$BUNDLE/Contents/MacOS/"
cp /opt/homebrew/opt/libangle/lib/libGLESv2.dylib "$BUNDLE/Contents/MacOS/"

# Direct kernel boot needs no firmware, but QEMU still resolves option ROMs
# (efi-virtio.rom and friends) from -L, so ship the table. The *source* tree
# holds the checked-in ROMs; the build tree only carries generated EDK2 images.
if [ -d "$ROOT/third_party/qemu-10.1.2/pc-bios" ]; then
    ditto "$ROOT/third_party/qemu-10.1.2/pc-bios" "$BUNDLE/Contents/Resources/pc-bios"
else
    echo "警告: 找不到 QEMU pc-bios，播放器将回退到源码树路径" >&2
fi

cat > "$BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>AndroPod</string>
    <key>CFBundleDisplayName</key>
    <string>AndroPod</string>
    <key>CFBundleIdentifier</key>
    <string>com.andropod.app</string>
    <key>CFBundleExecutable</key>
    <string>AndroPod</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <!-- This app owns no document windows worth restoring. Leaving window
         restoration on means every killed-and-relaunched debug cycle shows a
         modal "reopen windows?" alert, which blocks launch behind user input. -->
    <key>NSQuitAlwaysKeepsWindows</key>
    <false/>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSSupportsSuddenTermination</key>
    <false/>
</dict>
</plist>
PLIST

# 记录项目根：应用装进 /Applications 后，向上找不到 bin/andropod，
# 运行时靠这个文件回到源码树（实例、镜像、CLI 都在项目里）。
printf '{"root":"%s"}' "$ROOT" > "$BUNDLE/Contents/Resources/project-root.json"

# Ad-hoc signing, inside out: QEMU's HVF accelerator refuses to run without
# com.apple.security.hypervisor, and the player is the binary hosting it.
codesign --force --sign - "$BUNDLE/Contents/Frameworks/libandropod-qemu.dylib"
codesign --force --sign - "$BUNDLE/Contents/MacOS/andropod-player" \
    --entitlements "$EMBED/player.entitlements"
codesign --force --sign - "$BUNDLE"

# 安装到标准位置：Dock/Launchpad/Spotlight 只认这个路径，构建即生效。
# 旧进程必须先退——macOS 点 Dock 图标只会「激活」运行中的旧实例，不会加载
# 磁盘上的新构建，这正是「每次启动都是旧版」的原因。
INSTALL_DIR="/Applications"
[ -w "$INSTALL_DIR" ] || INSTALL_DIR="$HOME/Applications"
mkdir -p "$INSTALL_DIR"

INSTALLED="$INSTALL_DIR/AndroPod.app"
if [ -d "$INSTALLED" ]; then
    osascript -e 'tell application "AndroPod" to quit' >/dev/null 2>&1 || true
    pkill -f "$INSTALLED/Contents/MacOS/" 2>/dev/null || true
    sleep 1
fi
# ditto 合并覆盖而不是 rm 整个 .app：逐文件写入不触发批量删除拦截，
# 同名结构的覆盖足够让新二进制/资源生效。
ditto "$BUNDLE" "$INSTALLED"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$INSTALLED" 2>/dev/null || true

echo "已生成: $BUNDLE"
echo "已安装: $INSTALLED"
