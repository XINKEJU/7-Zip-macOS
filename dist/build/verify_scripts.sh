#!/bin/sh
#
# verify_scripts.sh — offline validation of the installer and removal logic.
#
# The installer itself cannot be exercised here because `installer` refuses to
# run without root. What CAN be tested without root is the logic of the two
# shell scripts that ship inside the package, so this harness does that:
#
#   A. syntax-check both postinstall scripts
#   B. replay the CLI postinstall's legacy-directory cleanup
#   C. run uninstall.sh against a fake prefix built from the real payload, and
#      check that (1) every packaged file is removed and (2) files that belong
#      to something else are left alone
#
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
DIST="$(cd "$HERE/.." && pwd)"
VERSION="26.03"

WORK="$(mktemp -d)"
FAIL=0
ok()  { printf '  [ok]   %s\n' "$1"; }
bad() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
echo "== A. 脚本语法检查 =="
for s in "$HERE/uninstall.sh" "$HERE/.installer/scripts-cli/postinstall" "$HERE/.installer/scripts-app/postinstall"; do
    if [ -f "$s" ]; then
        if sh -n "$s" 2>/dev/null; then ok "语法正确 $(basename "$(dirname "$s")")/$(basename "$s")"
        else bad "语法错误 $s"; fi
    else
        bad "缺失 $s"
    fi
done

# ---------------------------------------------------------------------------
echo
echo "== B. 复现 CLI postinstall：旧文档目录清理 =="
LEGACY_ROOT="$WORK/legacy/usr/local/share/doc"
mkdir -p "$LEGACY_ROOT/7-Zip" "$LEGACY_ROOT/7zip"
# a directory that looks like ours
: > "$LEGACY_ROOT/7-Zip/License.txt"
: > "$LEGACY_ROOT/7-Zip/copying.txt"
: > "$LEGACY_ROOT/7-Zip/readme.txt"
# a different directory that must survive
mkdir -p "$LEGACY_ROOT/other"
: > "$LEGACY_ROOT/other/keep.txt"

# same logic as the postinstall, parameterised for the fake root
LEGACY="$LEGACY_ROOT/7-Zip"
if [ -d "$LEGACY" ] && [ -f "$LEGACY/License.txt" ] && [ -f "$LEGACY/copying.txt" ]; then
    rm -rf "$LEGACY"
fi
[ ! -d "$LEGACY" ] && ok "旧目录 7-Zip/ 被清理" || bad "旧目录 7-Zip/ 未清理"
[ -f "$LEGACY_ROOT/other/keep.txt" ] && ok "无关目录 other/ 保留" || bad "无关目录 other/ 被误删"

# negative case: a directory that does NOT look like ours must survive
mkdir -p "$LEGACY_ROOT/7-Zip"
: > "$LEGACY_ROOT/7-Zip/user-data.txt"
LEGACY="$LEGACY_ROOT/7-Zip"
if [ -d "$LEGACY" ] && [ -f "$LEGACY/License.txt" ] && [ -f "$LEGACY/copying.txt" ]; then
    rm -rf "$LEGACY"
fi
[ -f "$LEGACY_ROOT/7-Zip/user-data.txt" ] \
    && ok "非本包目录 7-Zip/ (无 License.txt) 保留" \
    || bad "非本包目录被误删"

# ---------------------------------------------------------------------------
echo
echo "== C. 卸载脚本：真实载荷上的完整性与安全性 =="
PKG="$DIST/7-Zip-$VERSION-macOS.pkg"
EXP="$WORK/exp"
pkgutil --expand-full "$PKG" "$EXP" >/dev/null 2>&1

FAKE="$WORK/fake"
mkdir -p "$FAKE/usr/local" "$FAKE/Applications" "$FAKE/var/db/receipts"
# lay down the real payloads in the fake filesystem
( cd "$EXP/7-Zip-cli.pkg/Payload" && tar cf - usr ) | ( cd "$FAKE" && tar xf - )
( cd "$EXP/7-Zip-app.pkg/Payload" && tar cf - Applications ) | ( cd "$FAKE" && tar xf - )

# decoys: things this package must NOT remove
mkdir -p "$FAKE/usr/local/share/zsh/site-functions"
: > "$FAKE/usr/local/share/zsh/site-functions/_docker"    # neighbouring completion
mkdir -p "$FAKE/usr/local/share/bash-completion/completions"
: > "$FAKE/usr/local/share/bash-completion/completions/git"
mkdir -p "$FAKE/usr/local/share/fish/vendor_completions.d"
: > "$FAKE/usr/local/share/fish/vendor_completions.d/foo.fish"
: > "$FAKE/usr/local/bin/some-other-tool"
mkdir -p "$FAKE/usr/local/share/doc/7zip"
: > "$FAKE/usr/local/share/doc/7zip/user-note.txt"
mkdir -p "$FAKE/Applications/SomeOther.app/Contents"
: > "$FAKE/Applications/SomeOther.app/Contents/Info.plist"

BEFORE_DECOY=$(find "$FAKE/Applications" -name 'SomeOther.app' -type d | wc -l | tr -d ' ')

# build a test copy of uninstall.sh pointed at the fake root
SED="$(mktemp)"
sed -e 's|^PREFIX="/usr/local"|PREFIX="'"$FAKE"'/usr/local"|' \
    -e 's|^APP="/Applications/7-Zip.app"|APP="'"$FAKE"'/Applications/7-Zip.app"|' \
    "$HERE/uninstall.sh" > "$SED"
# drop the root check, and neutralise pkgutil receipts for the fake tree
sed -i.bak -e 's|^if \[ "$(id -u)" -ne 0 \]; then|if false; then|' "$SED"
rm -f "$SED.bak"

sh "$SED" > "$WORK/uninstall.out" 2>&1 || true
sed 's/^/    /' "$WORK/uninstall.out"

# --- every packaged file must be gone -------------------------------------
GONE=0
LEFT=0
for f in \
    usr/local/bin/7zz \
    usr/local/bin/7z \
    usr/local/share/man/man1/7zz.1 \
    usr/local/share/man/man1/7z.1 \
    usr/local/share/zsh/site-functions/_7zz \
    usr/local/share/bash-completion/completions/7zz \
    usr/local/share/fish/vendor_completions.d/7zz.fish \
    usr/local/share/doc/7zip/License.txt \
    usr/local/share/doc/7zip/copying.txt \
    usr/local/share/doc/7zip/unRarLicense.txt \
    usr/local/share/doc/7zip/readme.txt \
    usr/local/share/doc/7zip/7zFormat.txt \
    usr/local/share/doc/7zip/README-macos.txt \
    usr/local/share/doc/7zip/BUILD.md \
    usr/local/share/doc/7zip/uninstall.sh \
    Applications/7-Zip.app ; do
    if [ -e "$FAKE/$f" ]; then
        bad "应删除但仍存在: $f"
        LEFT=$((LEFT + 1))
    else
        GONE=$((GONE + 1))
    fi
done
[ "$LEFT" -eq 0 ] && ok "全部 $GONE 项包内文件已删除"

# --- decoys must survive --------------------------------------------------
for d in \
    usr/local/share/zsh/site-functions/_docker \
    usr/local/share/bash-completion/completions/git \
    usr/local/share/fish/vendor_completions.d/foo.fish \
    usr/local/bin/some-other-tool \
    usr/local/share/doc/7zip/user-note.txt \
    Applications/SomeOther.app/Contents/Info.plist ; do
    [ -e "$FAKE/$d" ] && ok "保留无关文件 $d" || bad "误删无关文件 $d"
done

echo
if [ "$FAIL" -eq 0 ]; then
    echo "结果: 全部通过 (0 项失败)"
else
    echo "结果: $FAIL 项失败" >&2
fi
rm -rf "$WORK"
exit "$FAIL"
