#!/bin/sh
#
# package.sh — assemble the redistributable macOS distribution tree.
#
# Inputs (all produced by the earlier build steps):
#   build/7zz                        universal CLI engine (arm64 + x86_64)
#   build/7zz.1, build/7z.1          manual pages
#   build/README-macos.txt           this port's end-user readme
#   build/BUILD.md                   how the port was built
#   shell/_7zz, 7zz.bash, 7zz.fish   shell completions
#   ../7z2603-src/DOC/*.txt          upstream licence, readme, format reference
#   ../THIRD_PARTY.md                third-party attribution and licences
#   mk_tarball.py                    the reproducible archiver (see below)
#
# NOTE: the native GUI application is deliberately *not* staged here. Homebrew
# cannot manage .app bundles or app extensions, so the application travels in
# the installer package (make_installer.sh) only. The formula's caveat block
# points users at that package.
#
# Outputs, written to the directory containing this script's parent:
#   pack/7zip-macos-26.03/           staged FHS-style tree
#   7zip-macos-26.03-macos-universal.tar.gz
#   7zip-macos-26.03-macos-universal.tar.gz.sha256
#
# The staged tree is what an installer package (pkgbuild) and the Homebrew
# formula both consume, so the two stay byte-for-byte consistent.
#
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
DIST="$(cd "$HERE/.." && pwd)"
SRC="$DIST/../7z2603-src"
VERSION="26.03"
NAME="7zip-macos-$VERSION"
STAGE="$DIST/pack/$NAME"
TARBALL="$DIST/$NAME-macos-universal.tar.gz"

echo "== 1. 校验输入 =="
for f in "$HERE/7zz" "$HERE/7zz.1" "$HERE/7z.1" "$HERE/README-macos.txt" \
         "$DIST/shell/_7zz" "$DIST/shell/7zz.bash" "$DIST/shell/7zz.fish"; do
    [ -f "$f" ] || { echo "缺少输入文件: $f" >&2; exit 1; }
done
for f in License.txt copying.txt readme.txt unRarLicense.txt 7zFormat.txt; do
    [ -f "$SRC/DOC/$f" ] || { echo "缺少 $SRC/DOC/$f" >&2; exit 1; }
done
echo "   输入齐全"

echo "== 2. 搭建立目录树 =="
# NOTE: do not "rm -rf $STAGE" here. A host security policy can block bulk
# recursive deletion, and because this script runs with `set -e` the blocked
# delete aborts the run *after* the artifacts were already written -- the build
# then looks like it succeeded while the archive keeps the previous contents.
# Moving the old tree out of the way is equivalent and cannot be blocked.
if [ -d "$STAGE" ]; then
    mv "$STAGE" "${TMPDIR:-/tmp}/7zip-pkg-stage.$$.$RANDOM"
fi
mkdir -p "$STAGE/bin" \
         "$STAGE/share/man/man1" \
         "$STAGE/share/zsh/site-functions" \
         "$STAGE/share/bash-completion/completions" \
         "$STAGE/share/fish/vendor_completions.d" \
         "$STAGE/share/doc/7zip"

install -m 0755 "$HERE/7zz"                        "$STAGE/bin/7zz"
install -m 0644 "$HERE/7zz.1"                      "$STAGE/share/man/man1/7zz.1"
install -m 0644 "$HERE/7z.1"                       "$STAGE/share/man/man1/7z.1"
install -m 0644 "$DIST/shell/_7zz"                 "$STAGE/share/zsh/site-functions/_7zz"
install -m 0644 "$DIST/shell/7zz.bash"             "$STAGE/share/bash-completion/completions/7zz"
install -m 0644 "$DIST/shell/7zz.fish"             "$STAGE/share/fish/vendor_completions.d/7zz.fish"

# --- upstream documentation ------------------------------------------------
# NOTE: do not name any file here "README.txt". The default macOS volume is
# case-insensitive, so "README.txt" and the upstream "readme.txt" resolve to
# the same directory entry and the second install silently overwrites the
# first. That is how the upstream readme was lost in an earlier revision.
install -m 0644 "$SRC/DOC/License.txt"             "$STAGE/share/doc/7zip/License.txt"
install -m 0644 "$SRC/DOC/copying.txt"             "$STAGE/share/doc/7zip/copying.txt"
install -m 0644 "$SRC/DOC/readme.txt"              "$STAGE/share/doc/7zip/readme.txt"
# The engine links the RAR decompressor, so the unRAR restriction text has to
# travel with the binary for the redistribution to be licence-complete.
install -m 0644 "$SRC/DOC/unRarLicense.txt"        "$STAGE/share/doc/7zip/unRarLicense.txt"
# Reference material for the .7z container format.
install -m 0644 "$SRC/DOC/7zFormat.txt"            "$STAGE/share/doc/7zip/7zFormat.txt"

# --- this port's own documentation ----------------------------------------
install -m 0644 "$HERE/README-macos.txt"           "$STAGE/share/doc/7zip/README-macos.txt"
[ -f "$HERE/BUILD.md" ]   && install -m 0644 "$HERE/BUILD.md"   "$STAGE/share/doc/7zip/BUILD.md"

# --- third-party attribution ----------------------------------------------
# P5: the composite licence notice has to travel with every redistributable,
# the Homebrew tarball included. It lives at the repository root, not in
# build/, because the installer package and the GitHub release both read it
# from there. Missing the file is a licence-completeness defect, so refuse
# rather than ship a silent gap.
if [ -f "$DIST/../THIRD_PARTY.md" ]; then
    install -m 0644 "$DIST/../THIRD_PARTY.md"      "$STAGE/share/doc/7zip/THIRD_PARTY.md"
else
    echo "缺少 THIRD_PARTY.md，分发包将不满足许可完整性要求" >&2
    exit 1
fi

echo "== 3. 归档 =="
# 归档由 mk_tarball.py 完成，而不是 /usr/bin/tar。macOS 自带的是 bsdtar
# 3.5.3，既不支持 GNU tar 的 --sort=name 也不支持 --mtime，因此无法在命令行
# 层面固定条目顺序与时间戳。结果是每次重建哈希都变，Homebrew 公式里那个
# sha256 每次都要手改，而 verify_formula.sh 又会断言两者相等。
# mk_tarball.py 固定条目顺序、mtime、属主与权限，使归档仅取决于文件名与内容：
# 只要二进制没变，sha256 就不变，公式里的值才是可复算的而非需要反复打补丁的。
PYTHON="${PYTHON:-python3}"
command -v "$PYTHON" >/dev/null 2>&1 || {
    echo "缺少 python3，无法生成可复现归档" >&2; exit 1; }
"$PYTHON" "$HERE/mk_tarball.py" "$DIST/pack" "$NAME" "$TARBALL"
shasum -a 256 "$TARBALL" | awk '{print $1}' > "$TARBALL.sha256"

echo "== 4. 结果 =="
printf '   %s\n' "$TARBALL"
printf '   sha256 %s\n' "$(cat "$TARBALL.sha256")"
printf '   内容:\n'
tar -tzf "$TARBALL" | sed 's/^/     /'
