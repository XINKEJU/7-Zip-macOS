#!/bin/sh
#
# build_app.sh — assembles 7-Zip.app from the sources in this directory.
#
# Produces a universal (arm64 + x86_64) application bundle with the patched
# 7zz engine embedded, ad-hoc signed and registered with LaunchServices.
#
# Usage:  sh build_app.sh <path-to-7zz-universal> <path-to-7zip.icns> <output-dir>

set -e

ENGINE="$1"
ICNS="$2"
OUTDIR="$3"
HERE="$(cd "$(dirname "$0")" && pwd)"

if [ -z "$ENGINE" ] || [ -z "$ICNS" ] || [ -z "$OUTDIR" ]; then
    echo "usage: sh build_app.sh <7zz> <7zip.icns> <output-dir>" >&2
    exit 1
fi

APP="$OUTDIR/7-Zip.app"
BUILD="$HERE/.build"

echo "== 1. 校验 Info.plist =="
plutil -lint "$HERE/Info.plist"

echo "== 2. 编译两个架构（部署目标 11.0）=="
mkdir -p "$BUILD"
export MACOSX_DEPLOYMENT_TARGET=11.0
for arch in arm64 x86_64; do
    clang -fobjc-arc -fmodules -Wall -O2 \
          -arch "$arch" -mmacosx-version-min=11.0 \
          -framework AppKit -framework Foundation \
          -o "$BUILD/app-$arch" "$HERE/main.m"
    printf "   %-8s %s bytes\n" "$arch" "$(stat -f%z "$BUILD/app-$arch")"
done

echo "== 3. 合并通用二进制 =="
lipo -create "$BUILD/app-arm64" "$BUILD/app-x86_64" -output "$BUILD/app-universal"
lipo -archs "$BUILD/app-universal" | sed 's/^/   架构: /'

echo "== 4. 组装 .app 包 =="
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/app-universal"        "$APP/Contents/MacOS/7-Zip"
cp "$HERE/Info.plist"            "$APP/Contents/Info.plist"
cp "$ICNS"                       "$APP/Contents/Resources/7zip.icns"
cp "$ENGINE"                     "$APP/Contents/Resources/7zz"
chmod 755 "$APP/Contents/MacOS/7-Zip" "$APP/Contents/Resources/7zz"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "== 5. 嵌入引擎校验 =="
EMBED="$(shasum -a 256 "$APP/Contents/Resources/7zz" | awk '{print $1}')"
SRC="$(shasum -a 256 "$ENGINE" | awk '{print $1}')"
[ "$EMBED" = "$SRC" ] && echo "   引擎与源产物一致" || { echo "   引擎不一致！" >&2; exit 1; }

echo "== 6. ad-hoc 签名 =="
codesign --force --deep --sign - --timestamp=none \
         --identifier org.7-zip.macos.app "$APP" 2>&1 | sed 's/^/   /'
codesign --verify --deep --strict "$APP" && echo "   签名校验通过"

echo "== 7. 构建 Quick Look 预览扩展 =="
# Order matters: --deep above re-signs nested code and would strip the
# extension's sandbox entitlement, so the extension is built (and the app
# re-sealed without --deep) only after the base bundle exists.
QLBUILD="$OUTDIR/ql-src/build_ql.sh"
if [ -x "$QLBUILD" ]; then
    APP_BUNDLE="$APP" sh "$QLBUILD" 2>&1 | sed 's/^/   /'
else
    echo "   未找到 $QLBUILD，跳过"
fi

echo "== 8. 注册到 LaunchServices =="
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if [ -x "$LSREG" ]; then
    "$LSREG" -f "$APP" && echo "   已注册"
else
    echo "   未找到 lsregister，跳过"
fi
if [ -d "$APP/Contents/PlugIns/7ZipQuickLook.appex" ]; then
    pluginkit -a "$APP/Contents/PlugIns/7ZipQuickLook.appex" \
        && echo "   Quick Look 扩展已注册" || true
fi

echo
echo "== 结果 =="
du -sh "$APP" | sed 's/^/   /'
find "$APP" -type f -o -type l | sed "s|$APP|   7-Zip.app|"
