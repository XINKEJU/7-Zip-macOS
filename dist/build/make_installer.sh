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
#   build/7zz                      universal CLI engine
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
#   7-Zip-26.03-macOS-universal.tar.xz       command line tools only
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
TARXZ="$DIST/7-Zip-$VERSION-macOS-universal.tar.xz"

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

# The application must carry its own embedded engine, otherwise the Finder
# context menu has nothing to run.
if [ -f "$APP_SRC/Contents/Resources/7zz" ]; then
    printf '   ok      embedded engine in 7-Zip.app\n'
else
    printf '   MISSING embedded engine in 7-Zip.app\n' >&2
    missing=1
fi
[ "$missing" -eq 0 ] || { echo "输入不完整，终止。" >&2; exit 1; }

# ---------------------------------------------------------------------------
echo "== 2. 搭建 CLI 载荷 (-> /usr/local) =="
rm -rf "$WORK"
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

rm -f "$PKG"
productbuild --distribution "$DIST/distribution.xml" \
             --resources "$RES" \
             --package-path "$PKGDIR" \
             "$PKG"
printf '   %s  %s bytes\n' "$(basename "$PKG")" "$(stat -f%z "$PKG")"

# ---------------------------------------------------------------------------
echo "== 7. 磁盘映像 (.dmg) =="
mkdir -p "$DMGSTAGE"
cp "$PKG"                       "$DMGSTAGE/"
cp "$HERE/README-macos.txt"     "$DMGSTAGE/README-macos.txt"
cp "$HERE/uninstall.sh"         "$DMGSTAGE/uninstall.sh"
chmod 755 "$DMGSTAGE/uninstall.sh"

rm -f "$DMG"
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
echo
echo "== 完成 =="
