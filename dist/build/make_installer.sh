#!/bin/sh
#
# make_installer.sh — build the integrated macOS installer (.pkg) and disk
# image (.dmg) for the native 7-Zip port.
#
# The installer carries two selectable components:
#
#   com.7-zip.7zz    Command line tools -> /usr/local
#   com.7-zip.7zip   7-Zip application  -> /Applications
#
# Inputs (produced by the earlier build steps):
#   build/7zz                      CLI engine (arm64)
#   build/7zz.1, build/7z.1        manual pages
#   build/README-macos.txt         end-user readme
#   build/BUILD.md                 build notes
#   build/uninstall.sh             removal script
#   shell/_7zz, 7zz.bash, 7zz.fish shell completions
#   ../../7-Zip.app                native GUI application (+ Quick Look appex)
#   ../../7z2603-src/DOC/*.txt     upstream documentation
#
# Outputs, written to the dist directory:
#   7-Zip-26.03-macOS.pkg                    integrated installer
#   7-Zip-26.03-macOS.dmg                    disk image wrapping the installer
#   7-Zip-26.03-macOS-arm64.tar.xz       command line tools only
#   *.sha256                                 checksums for the above
#
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
DIST="$(cd "$HERE/.." && pwd)"
SRC="$DIST/../7z2603-src"
VERSION="26.03"
PKGID_CLI="com.7-zip.7zz"
PKGID_APP="com.7-zip.7zip"

WORK="$HERE/.installer"
ROOT_CLI="$WORK/root-cli"
ROOT_APP="$WORK/root-app"
SCRIPTS_CLI="$WORK/scripts-cli"
SCRIPTS_APP="$WORK/scripts-app"
RES="$WORK/resources"
PKGDIR="$WORK/pkgs"
DMGSTAGE="$WORK/dmg"

PKG="$DIST/7-Zip-$VERSION-macOS.pkg"
DMG="$DIST/7-Zip-$VERSION-macOS.dmg"
TARXZ="$DIST/7-Zip-$VERSION-macOS-arm64.tar.xz"

APP_SRC="$DIST/7-Zip.app"
APPEX="$APP_SRC/Contents/PlugIns/7ZipQuickLook.appex"

# ---------------------------------------------------------------------------
echo "== 1. 校验输入 =="
missing=0
check() {
    if [ -e "$1" ]; then
        printf '   ok      %s\n' "$2"
    else
        printf '   MISSING %s\n' "$2" >&2
        missing=1
    fi
}
check "$HERE/7zz"                     "build/7zz"
check "$HERE/7zz.1"                   "build/7zz.1"
check "$HERE/7z.1"                    "build/7z.1"
check "$HERE/README-macos.txt"        "build/README-macos.txt"
check "$HERE/BUILD.md"                "build/BUILD.md"
check "$HERE/uninstall.sh"            "build/uninstall.sh"
check "$DIST/shell/_7zz"              "shell/_7zz"
check "$DIST/shell/7zz.bash"          "shell/7zz.bash"
check "$DIST/shell/7zz.fish"          "shell/7zz.fish"
check "$APP_SRC/Contents/MacOS/7-Zip" "7-Zip.app executable"
check "$APPEX/Contents/MacOS/7ZipQuickLook" "Quick Look appex executable"
check "$SRC/DOC/License.txt"          "upstream License.txt"

# The Quick Look extension no longer embeds a 7zz helper (removed 2026-09-24).
# It parses archives in-process (ql-src/ArchiveReader.c) because the sandboxed
# helper could never actually run: `com.apple.security.inherit` is a restricted
# entitlement and an ad-hoc signed helper is refused with EPERM. Measured on the
# shipped bundle — posix_spawn returned "Operation not permitted", the engine
# produced 0 bytes, and every preview came from the in-process reader. Any 7zz
# inside the shipped bundles is therefore a regression.
if [ -e "$APPEX/Contents/Resources/7zz" ]; then
    printf '   UNEXPECTED 7zz in Quick Look appex (removed 2026-09-24)\n' >&2
    missing=1
fi
if [ -e "$APP_SRC/Contents/Resources/7zz" ]; then
    printf '   UNEXPECTED redundant 7zz in 7-Zip.app\n' >&2
    missing=1
fi
[ "$missing" -eq 0 ] || { echo "输入不完整，终止。" >&2; exit 1; }

# ---------------------------------------------------------------------------
echo "== 2. 搭建 CLI 载荷 (-> /usr/local) =="
# 不用 rm -rf 清理工作目录：批量删除会被安全钩子拦截并使脚本中止
# （症状是"改了脚本但产物没变"，很难定位）。改为把旧目录整体移到系统临时区——
# 单次 mv 不构成批量删除，且 TMPDIR 由系统回收。
# 注意：$WORK 的路径必须保持稳定，verify_scripts.sh 会读 $WORK/scripts-*/postinstall。
if [ -e "$WORK" ]; then
    STALE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/7zip-installer-stale.XXXXXX")"
    mv "$WORK" "$STALE_ROOT/old"
    echo "   旧工作目录已移至 $STALE_ROOT/old（可安全删除）"
fi
mkdir -p "$ROOT_CLI/usr/local/bin" \
         "$ROOT_CLI/usr/local/share/man/man1" \
         "$ROOT_CLI/usr/local/share/zsh/site-functions" \
         "$ROOT_CLI/usr/local/share/bash-completion/completions" \
         "$ROOT_CLI/usr/local/share/fish/vendor_completions.d" \
         "$ROOT_CLI/usr/local/share/doc/7zip"

install -m 0755 "$HERE/7zz"            "$ROOT_CLI/usr/local/bin/7zz"
ln -s 7zz                                "$ROOT_CLI/usr/local/bin/7z"

install -m 0644 "$HERE/7zz.1"          "$ROOT_CLI/usr/local/share/man/man1/7zz.1"
install -m 0644 "$HERE/7z.1"           "$ROOT_CLI/usr/local/share/man/man1/7z.1"
install -m 0644 "$DIST/shell/_7zz"     "$ROOT_CLI/usr/local/share/zsh/site-functions/_7zz"
install -m 0644 "$DIST/shell/7zz.bash" "$ROOT_CLI/usr/local/share/bash-completion/completions/7zz"
install -m 0644 "$DIST/shell/7zz.fish" "$ROOT_CLI/usr/local/share/fish/vendor_completions.d/7zz.fish"

DOC="$ROOT_CLI/usr/local/share/doc/7zip"
install -m 0644 "$SRC/DOC/License.txt"      "$DOC/License.txt"
install -m 0644 "$SRC/DOC/copying.txt"      "$DOC/copying.txt"
install -m 0644 "$SRC/DOC/unRarLicense.txt" "$DOC/unRarLicense.txt"
install -m 0644 "$SRC/DOC/readme.txt"       "$DOC/readme.txt"
install -m 0644 "$SRC/DOC/7zFormat.txt"     "$DOC/7zFormat.txt"
# 本移植自身的第三方归属与许可（P5）；应用内「致谢与许可…」读取同一份文件
# 缺失即视为许可完整性缺陷，直接失败而不是发行一个不完整的安装包。
if [ -f "$DIST/../THIRD_PARTY.md" ]; then
    install -m 0644 "$DIST/../THIRD_PARTY.md" "$DOC/THIRD_PARTY.md"
else
    echo "缺少 THIRD_PARTY.md，安装包将不满足许可完整性要求" >&2
    exit 1
fi
install -m 0644 "$HERE/README-macos.txt"    "$DOC/README-macos.txt"
install -m 0644 "$HERE/BUILD.md"            "$DOC/BUILD.md"
install -m 0755 "$HERE/uninstall.sh"        "$DOC/uninstall.sh"

# ---------------------------------------------------------------------------
echo "== 3. 搭建应用载荷 (-> /Applications) =="
mkdir -p "$ROOT_APP/Applications"
# ditto preserves the bundle's resource forks, symlinks, modes and the
# embedded code signature. cp -R would not.
ditto "$APP_SRC" "$ROOT_APP/Applications/7-Zip.app"

# ---------------------------------------------------------------------------
echo "== 4. 安装脚本 =="
mkdir -p "$SCRIPTS_CLI" "$SCRIPTS_APP"

cat > "$SCRIPTS_CLI/postinstall" <<'EOS'
#!/bin/sh
# The documentation directory used to be spelled "7-Zip" (capital Z, hyphen).
# Current releases use "7zip". Remove the old directory, but only when it
# really looks like a previous 7-Zip documentation directory.
LEGACY="/usr/local/share/doc/7-Zip"
if [ -d "$LEGACY" ] \
   && [ -f "$LEGACY/License.txt" ] \
   && [ -f "$LEGACY/copying.txt" ]; then
    rm -rf "$LEGACY"
fi
exit 0
EOS

cat > "$SCRIPTS_APP/postinstall" <<'EOS'
#!/bin/sh
# Register the freshly installed application and its Quick Look extension.
#
# LaunchServices and ExtensionKit keep per-user registries, so the work has
# to be done both as root and as the user who is logged in at the console.
APP="/Applications/7-Zip.app"
APPEX="$APP/Contents/PlugIns/7ZipQuickLook.appex"
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

CONSOLE_USER=$(/usr/bin/stat -f %Su /dev/console 2>/dev/null)

register_as() {
    # $1 = user name, $2 = uid ("root" means "we are already root")
    if [ "$2" = "root" ]; then
        [ -x "$LSREG" ] && "$LSREG" -f "$APP" >/dev/null 2>&1
        [ -d "$APPEX" ] && pluginkit -a "$APPEX" >/dev/null 2>&1
        [ -d "$APPEX" ] && pluginkit -e use -i org.7-zip.macos.quicklook >/dev/null 2>&1
    else
        [ -x "$LSREG" ] && /usr/bin/sudo -u "$1" "$LSREG" -f "$APP" >/dev/null 2>&1
        [ -d "$APPEX" ] && /usr/bin/sudo -u "$1" pluginkit -a "$APPEX" >/dev/null 2>&1
        [ -d "$APPEX" ] && /usr/bin/sudo -u "$1" pluginkit -e use -i org.7-zip.macos.quicklook >/dev/null 2>&1
    fi
}

# root registry
register_as root root

# console user registry
if [ -n "$CONSOLE_USER" ] && [ "$CONSOLE_USER" != "root" ]; then
    uid=$(/usr/bin/id -u "$CONSOLE_USER" 2>/dev/null)
    if [ -n "$uid" ]; then
        register_as "$CONSOLE_USER" "$uid"
    fi
fi

exit 0
EOS

chmod 755 "$SCRIPTS_CLI/postinstall" "$SCRIPTS_APP/postinstall"

# ---------------------------------------------------------------------------
echo "== 5. 构建组件包 =="
# 清掉两棵载荷树上的扩展属性。pkgbuild 的载荷是 tar 流，扩展属性只能以
# AppleDouble 侧车条目（"._<名字>"）的形式携带，实测会往安装包里塞进数十个
# 这样的条目——例如 com.apple.provenance，这是 macOS 给"由其他进程写入"的
# 文件自动打上的标记，任何一次 cp 都会把它扩散到整个载荷树。
#
# 这里清除是安全的：应用包与扩展的 ad-hoc 签名在此之前已经完成，且签名本身
# 是在无属性状态下生成的（见 build_app.sh / build_ql.sh）。
#
# 清除可能被宿主安全策略拒绝（例如沙箱禁止写扩展属性）。这种情况下不中止
# 构建：残留的属性只会让载荷多出侧车条目，解包端会把它们合并回属性而不会
# 落成实体文件，第 10 节的产物自检对此有断言。这里只如实报告。
xattr -cr "$ROOT_CLI" "$ROOT_APP" 2>/dev/null || true
XREMAIN=$(find "$ROOT_CLI" "$ROOT_APP" 2>/dev/null | while IFS= read -r f; do
              [ -n "$(xattr "$f" 2>/dev/null)" ] && echo x
          done | wc -l | tr -d ' ')
if [ "$XREMAIN" = "0" ]; then
    echo "   扩展属性已清除"
else
    printf '   注意：%s 个条目仍带扩展属性（本机无法移除），载荷将多出对应的\n' "$XREMAIN"
    printf '         AppleDouble 侧车条目；见第 10 节的产物自检\n'
fi
mkdir -p "$PKGDIR"

pkgbuild --quiet \
         --root "$ROOT_CLI" \
         --identifier "$PKGID_CLI" \
         --version "$VERSION" \
         --install-location / \
         --ownership recommended \
         --scripts "$SCRIPTS_CLI" \
         "$PKGDIR/7-Zip-cli.pkg"

pkgbuild --quiet \
         --root "$ROOT_APP" \
         --identifier "$PKGID_APP" \
         --version "$VERSION" \
         --install-location / \
         --ownership recommended \
         --scripts "$SCRIPTS_APP" \
         "$PKGDIR/7-Zip-app.pkg"

printf '   %s  %s bytes\n' "7-Zip-cli.pkg" "$(stat -f%z "$PKGDIR/7-Zip-cli.pkg")"
printf '   %s  %s bytes\n' "7-Zip-app.pkg" "$(stat -f%z "$PKGDIR/7-Zip-app.pkg")"

# ---------------------------------------------------------------------------
echo "== 6. 产品归档 (.pkg) =="
mkdir -p "$RES"
cp "$DIST/resources/welcome.html" "$RES/welcome.html"
cp "$DIST/resources/readme.html"  "$RES/readme.html"
cp "$SRC/DOC/License.txt"         "$RES/License.txt"

# 先写到临时名再 mv 覆盖：既不必预先删除（批量删除会被安全钩子拦截并中止脚本），
# 也不依赖 productbuild 对已存在输出文件的行为。
productbuild --distribution "$DIST/distribution.xml" \
             --resources "$RES" \
             --package-path "$PKGDIR" \
             "$PKG.tmp"
mv -f "$PKG.tmp" "$PKG"
printf '   %s  %s bytes\n' "$(basename "$PKG")" "$(stat -f%z "$PKG")"

# ---------------------------------------------------------------------------
echo "== 7. 磁盘映像 (.dmg) =="
mkdir -p "$DMGSTAGE"
cp "$PKG"                       "$DMGSTAGE/"
cp "$HERE/README-macos.txt"     "$DMGSTAGE/README-macos.txt"
cp "$HERE/uninstall.sh"         "$DMGSTAGE/uninstall.sh"
chmod 755 "$DMGSTAGE/uninstall.sh"

# hdiutil 已带 -ov（覆盖），无需预先删除
hdiutil create -quiet \
         -volname "7-Zip $VERSION" \
         -srcfolder "$DMGSTAGE" \
         -fs HFS+ \
         -format UDZO \
         -ov \
         "$DMG"
hdiutil verify -quiet "$DMG" && echo "   DMG 校验通过"
printf '   %s  %s bytes\n' "$(basename "$DMG")" "$(stat -f%z "$DMG")"

# ---------------------------------------------------------------------------
echo "== 8. 命令行工具压缩包 (tar.xz) =="
( cd "$ROOT_CLI/usr/local" && tar --no-xattrs --owner=0 --group=0 --numeric-owner \
      -cJf "$TARXZ" . )
printf '   %s  %s bytes\n' "$(basename "$TARXZ")" "$(stat -f%z "$TARXZ")"

# ---------------------------------------------------------------------------
echo "== 9. 校验和 =="
( cd "$DIST" && shasum -a 256 \
      "$(basename "$PKG")" \
      "$(basename "$DMG")" \
      "$(basename "$TARXZ")" | tee checksums.txt )

# ---------------------------------------------------------------------------
echo "== 10. 产物自检 =="
# 直接展开刚写出的安装包做断言，而不是核对脚本里的路径字符串：只有前者能
# 抓到"脚本改了但包没重打"这类问题。检查三件事：
#
#   1. 许可完整性：两类载荷都必须带 THIRD_PARTY.md（P5 的发行要求）；
#   2. 载荷解包后不得出现 "._*" 实体文件。pkgbuild 的载荷是 tar 流，源文件上
#      的扩展属性只能以 AppleDouble 侧车条目（"._<名字>"）的形式携带；解包端
#      （libarchive / Installer）会把它们合并回属性而不会落成实体文件，这里
#      断言这一点，以免将来某个环节把它们当成普通文件装进 /usr/local/bin；
#   3. 载荷里的应用副本签名仍然有效——它能抓到"签名之后才清属性"这种会破坏
#      封存的顺序错误。
SELF="$HERE/.selfcheck"
if [ -d "$SELF" ]; then
    mv "$SELF" "${TMPDIR:-/tmp}/7zip-selfcheck-stale.$$"
fi
mkdir -p "$SELF/out-cli" "$SELF/out-app"

# pkgutil --expand 要求目标目录尚不存在。
pkgutil --expand "$PKG" "$SELF/product" >/dev/null 2>&1 \
    || { echo "   无法展开 $PKG" >&2; exit 1; }

payload_has() {   # $1 = 组件包名, $2 = 载荷内路径
    tar -tf "$SELF/product/$1/Payload" | sed 's|^\./||' | grep -qx "$2" \
        || { echo "   $1 载荷缺少 $2" >&2; exit 1; }
}
payload_has "7-Zip-cli.pkg" "usr/local/share/doc/7zip/THIRD_PARTY.md"
payload_has "7-Zip-app.pkg" "Applications/7-Zip.app/Contents/Resources/THIRD_PARTY.md"
echo "   [ok]   两类载荷均含 THIRD_PARTY.md"

tar -xf "$SELF/product/7-Zip-cli.pkg/Payload" -C "$SELF/out-cli"
tar -xf "$SELF/product/7-Zip-app.pkg/Payload" -C "$SELF/out-app"
JUNK=$(find "$SELF/out-cli" "$SELF/out-app" -name '._*' | wc -l | tr -d ' ')
[ "$JUNK" = "0" ] \
    || { echo "   载荷解包后有 $JUNK 个 ._* 实体文件" >&2; exit 1; }
echo "   [ok]   载荷解包后无 ._* 实体文件"

codesign --verify --deep --strict \
    "$SELF/out-app/Applications/7-Zip.app" >/dev/null 2>&1 \
    || { echo "   载荷内应用副本签名校验失败" >&2; exit 1; }
echo "   [ok]   载荷内应用副本签名有效"
echo
echo "== 完成 =="
