#!/bin/bash
#
# build_ql.sh — Build the 7-Zip Quick Look preview extension (.appex)
#
# Produces a universal (arm64 + x86_64) Quick Look preview extension and,
# when APP_BUNDLE is set, installs it into the host application's PlugIns
# directory so Finder can offer Space-bar previews for archive files.
#
# The extension lists archives in-process (see ArchiveReader.c). It deliberately
# does NOT embed the `7zz` console engine any more.
#
# Why: running an embedded helper from inside the extension's App Sandbox needs
# the restricted entitlement `com.apple.security.inherit`, which the kernel only
# grants to binaries signed with a real Developer ID and a matching provisioning
# profile. This project ships ad-hoc signed (`codesign --sign -`,
# TeamIdentifier=not set), so every spawn is refused with EPERM.
#
# Measured 2026-09-24 against the shipped bundle:
#     engine unavailable: posix_spawn 失败：Operation not permitted (errno 1)
#     engine run: raw=0 bytes
#     native reader: recognised=1 format=ZIP complete=1 count=4
# i.e. the engine never produced a single byte, and the whole preview came from
# the in-process reader. The embedded copy was 6,012,576 bytes — 48% of the
# entire .app — and never executed successfully once.
# Evidence: ~/Library/Containers/org.7-zip.macos.quicklook/Data/tmp/7zip-quicklook.log
#
# Should this project ever adopt a Developer ID signature, the full-engine
# listing path can be restored by copying the engine back into the bundle and
# signing it with its own entitlements:
#     cp "$DIST/build/7zz" "$OUT/Contents/Resources/7zz"   # chmod 755
#     { com.apple.security.app-sandbox : true,
#       com.apple.security.inherit     : true }
#
# Requirements: macOS 12+, Command Line Tools.
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DIST="$(cd "$HERE/.." && pwd)"
BUILD="$HERE/.build"
APP_BUNDLE="${APP_BUNDLE:-$DIST/7-Zip.app}"
EXEC_NAME="7ZipQuickLook"
BUNDLE_ID="org.7-zip.macos.quicklook"
MIN_MACOS="12.0"
OUT="$BUILD/$EXEC_NAME.appex"

echo "==> 7-Zip Quick Look extension build"
echo "    source : $HERE"
echo "    output : $OUT"

# 不删除旧的 .build：批量 rm 会被安全钩子拦截并中止脚本（伪装成"改动无效"）。
# 就地覆盖即可——两个架构每次都会重新编译，lipo/ditto 也都会覆盖目标。
mkdir -p "$BUILD"

# ---------------------------------------------------------------- compile ---
# QLPreviewProvider / QLPreviewReply are macOS 12 APIs, hence MIN_MACOS=12.0.
#
# The executable is built as an MH_EXECUTE with NSExtensionMain as the entry
# point — this is what Xcode does for `com.apple.product-type.app-extension`.
# Building with `-bundle` (MH_BUNDLE) instead would produce a plugin that the
# system refuses to launch, and ad-hoc signing silently drops entitlements for
# MH_BUNDLE binaries, so the sandbox entitlement would never stick.
compile_slice() {
  local arch="$1"
  echo "==> compiling $arch"
  clang \
    -arch "$arch" \
    -mmacosx-version-min="$MIN_MACOS" \
    -fobjc-arc -fmodules \
    -O2 -Wall -Wextra \
    -Wl,-e,_NSExtensionMain \
    -framework Foundation \
    -framework QuickLookUI \
    -framework UniformTypeIdentifiers \
    -o "$BUILD/$EXEC_NAME.$arch" \
    "$HERE/SevenZipPreviewProvider.m" \
    "$HERE/ArchiveReader.c"
}

compile_slice arm64
compile_slice x86_64

echo "==> creating universal binary"
lipo -create \
  "$BUILD/$EXEC_NAME.arm64" \
  "$BUILD/$EXEC_NAME.x86_64" \
  -output "$BUILD/$EXEC_NAME"

# ---------------------------------------------------------------- bundle ----
echo "==> assembling bundle"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BUILD/$EXEC_NAME" "$OUT/Contents/MacOS/$EXEC_NAME"
cp "$HERE/Info.plist" "$OUT/Contents/Info.plist"

# The engine is not embedded (see the header comment). cp/ditto only ever
# overwrite — they never prune — so a copy left behind by an earlier build must
# be removed explicitly, or it would silently survive here and in the .app.
rm -f "$OUT/Contents/Resources/7zz"

plutil -lint "$OUT/Contents/Info.plist"

# ------------------------------------------------------------------ sign ----
# Ad-hoc signature. There is no nested code to sign any more: the engine is no
# longer embedded.
#
# The extension itself must be sandboxed (ExtensionKit requirement).
echo "==> signing"
# 清除扩展属性，且必须在签名之前：pkgbuild 会把扩展属性编码成 AppleDouble
# 侧车文件（" ._<名字>"）混入安装包载荷，而签名一旦完成，属性即被封存，
# 之后再清除就等于破坏签名。
xattr -cr "$OUT" 2>/dev/null || true
codesign --force --sign - --timestamp=none \
  --entitlements "$HERE/7ZipQuickLook.entitlements" \
  "$OUT"

# --------------------------------------------------------------- install ----
if [ -d "$APP_BUNDLE" ]; then
  echo "==> installing into $APP_BUNDLE/Contents/PlugIns"
  mkdir -p "$APP_BUNDLE/Contents/PlugIns"
  # 同理不删旧 appex：ditto 会就地覆盖。若曾有文件被移除，外层
  # codesign --verify --deep --strict 会因未签名残留而报错，可作为守卫。
  # 正因如此，早期版本复制进来的 7zz 必须显式删除——ditto 不会清理多余文件，
  # 残留会让外层 --strict 校验失败。
  mkdir -p "$APP_BUNDLE/Contents/PlugIns/$EXEC_NAME.appex"
  rm -f "$APP_BUNDLE/Contents/PlugIns/$EXEC_NAME.appex/Contents/Resources/7zz"
  ditto "$OUT" "$APP_BUNDLE/Contents/PlugIns/$EXEC_NAME.appex"
  # Re-seal only the outer bundle. `--deep` must NOT be used here: it would
  # re-sign the nested extension without its entitlements, and a sandboxed
  # extension that loses `com.apple.security.app-sandbox` will not register.
  codesign --force --sign - --timestamp=none "$APP_BUNDLE"
fi

echo
echo "==> done"
file "$OUT/Contents/MacOS/$EXEC_NAME"
echo "    Resources:"
ls -la "$OUT/Contents/Resources" | tail -n +2
echo "    appex total: $(du -sh "$OUT" | cut -f1)"
