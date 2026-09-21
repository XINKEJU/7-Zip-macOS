#!/bin/bash
#
# build_ql.sh — Build the 7-Zip Quick Look preview extension (.appex)
#
# Produces a universal (arm64 + x86_64) Quick Look preview extension and,
# when APP_BUNDLE is set, installs it into the host application's PlugIns
# directory so Finder can offer Space-bar previews for archive files.
#
# Requirements: macOS 12+, Command Line Tools, dist/build/7zz present.
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DIST="$(cd "$HERE/.." && pwd)"
BUILD="$HERE/.build"
TOOL="$DIST/build/7zz"
APP_BUNDLE="${APP_BUNDLE:-$DIST/7-Zip.app}"
EXEC_NAME="7ZipQuickLook"
BUNDLE_ID="org.7-zip.macos.quicklook"
MIN_MACOS="12.0"
OUT="$BUILD/$EXEC_NAME.appex"

echo "==> 7-Zip Quick Look extension build"
echo "    source : $HERE"
echo "    output : $OUT"

if [ ! -x "$TOOL" ]; then
  echo "error: 7zz not found at $TOOL — build the CLI engine first." >&2
  exit 1
fi

rm -rf "$BUILD"
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

# Embed the engine so the extension is self-contained and immune to changes
# in the CLI install path.
cp "$TOOL" "$OUT/Contents/Resources/7zz"
chmod 755 "$OUT/Contents/Resources/7zz"

plutil -lint "$OUT/Contents/Info.plist"

# ------------------------------------------------------------------ sign ----
# Ad-hoc signature. Nested code is signed first so the outer bundle seals a
# consistent hash tree.
#
# The extension must be sandboxed (ExtensionKit requirement), and the embedded
# engine it spawns must carry `com.apple.security.inherit` so it joins the
# extension's sandbox and can read the archive under preview.
echo "==> signing"
codesign --force --sign - --timestamp=none \
  --entitlements "$HERE/7zz-helper.entitlements" \
  "$OUT/Contents/Resources/7zz"
codesign --force --sign - --timestamp=none \
  --entitlements "$HERE/7ZipQuickLook.entitlements" \
  "$OUT"

# --------------------------------------------------------------- install ----
if [ -d "$APP_BUNDLE" ]; then
  echo "==> installing into $APP_BUNDLE/Contents/PlugIns"
  mkdir -p "$APP_BUNDLE/Contents/PlugIns"
  rm -rf "$APP_BUNDLE/Contents/PlugIns/$EXEC_NAME.appex"
  ditto "$OUT" "$APP_BUNDLE/Contents/PlugIns/$EXEC_NAME.appex"
  # Re-seal only the outer bundle. `--deep` must NOT be used here: it would
  # re-sign the nested extension without its entitlements, and a sandboxed
  # extension that loses `com.apple.security.app-sandbox` will not register.
  codesign --force --sign - --timestamp=none "$APP_BUNDLE"
fi

echo
echo "==> done"
file "$OUT/Contents/MacOS/$EXEC_NAME"
ls -la "$OUT/Contents/Resources/7zz"
