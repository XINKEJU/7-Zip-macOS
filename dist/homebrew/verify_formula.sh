#!/bin/sh
#
# verify_formula.sh — validate the Homebrew formula without Homebrew.
#
# `brew` cannot be used in this environment: its vendored portable-ruby 4.0.6
# loads json 2.21.2, which raises
#   undefined method 'default_sort_keys_proc=' for class JSON::Ext::Generator::State
# while the CLI is still booting. That crash is unrelated to this formula.
#
# This script therefore reimplements the two parts of the formula that can
# actually fail -- the `install` staging map and the `test do` assertions --
# and replays them verbatim against a throw-away prefix.
#
# Homebrew's default install layout for a formula named sevenzip-macos:
#   url stage ............ <prefix>/Cellar/<name>/<version>
#   bin.install .......... <prefix>/bin
#   man1.install ......... <prefix>/share/man/man1
#   zsh_completion ....... <prefix>/share/zsh/site-functions
#   bash_completion ...... <prefix>/share/bash-completion/completions
#   fish_completion ...... <prefix>/share/fish/vendor_completions.d
#   doc.install .......... <prefix>/share/doc/<formula name>
#
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
DIST="$(cd "$HERE/.." && pwd)"
FORMULA="$HERE/sevenzip-macos.rb"
NAME="sevenzip-macos"
VERSION="26.03"

PREFIX="$(mktemp -d)/prefix"
TARBALL="$DIST/7zip-macos-$VERSION-macos-arm64.tar.gz"
CHECKSUM_FILE="$TARBALL.sha256"
FAIL=0

ok()   { printf '  [ok]   %s\n' "$1"; }
bad()  { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }

echo "== 1. 公式元数据 vs 实际产物 =="
FORMULA_SHA=$(awk -F'"' '/^  sha256 /{print $2}' "$FORMULA")
FORMULA_URL=$(awk -F'"' '/^  url /{print $2}' "$FORMULA")
FORMULA_VER=$(awk -F'"' '/^  version /{print $2}' "$FORMULA")
ACTUAL_SHA=$(shasum -a 256 "$TARBALL" | awk '{print $1}')

echo "  formula url     : $FORMULA_URL"
echo "  formula sha256  : $FORMULA_SHA"
echo "  tarball sha256  : $ACTUAL_SHA"
echo "  formula version : $FORMULA_VER"
echo "  tarball version : $VERSION"

[ "$FORMULA_SHA" = "$ACTUAL_SHA" ] \
    && ok "sha256 与 tarball 一致" \
    || bad "sha256 不一致"
[ "$FORMULA_VER" = "$VERSION" ] \
    && ok "version 与 tarball 一致" \
    || bad "version 不一致"
case "$FORMULA_URL" in
    *"v$VERSION/7zip-macos-$VERSION-macos-arm64.tar.gz") ok "url 指向 v$VERSION 下的同名产物" ;;
    *) bad "url 与产物文件名不符: $FORMULA_URL" ;;
esac
[ "$(cat "$CHECKSUM_FILE")" = "$ACTUAL_SHA" ] \
    && ok ".sha256 旁车文件自洽" \
    || bad ".sha256 旁车文件不自洽"

echo
echo "== 2. 复现 install 块 (staging map) =="
mkdir -p "$PREFIX/bin" \
         "$PREFIX/share/man/man1" \
         "$PREFIX/share/zsh/site-functions" \
         "$PREFIX/share/bash-completion/completions" \
         "$PREFIX/share/fish/vendor_completions.d" \
         "$PREFIX/share/doc/$NAME"

SRC="$(mktemp -d)/src"
mkdir -p "$SRC"
tar -xzf "$TARBALL" -C "$SRC"
ROOT="$SRC/7zip-macos-$VERSION"

# bin.install "bin/7zz"
if [ -f "$ROOT/bin/7zz" ]; then
    install -m 0755 "$ROOT/bin/7zz" "$PREFIX/bin/7zz"
    ok "bin.install bin/7zz"
else
    bad "bin/7zz 不存在于 tarball 中"
fi

# man1.install "share/man/man1/7zz.1" / "share/man/man1/7z.1"
for m in 7zz.1 7z.1; do
    if [ -f "$ROOT/share/man/man1/$m" ]; then
        install -m 0644 "$ROOT/share/man/man1/$m" "$PREFIX/share/man/man1/$m"
        ok "man1.install share/man/man1/$m"
    else
        bad "share/man/man1/$m 不存在于 tarball 中"
    fi
done

# zsh_completion.install "share/zsh/site-functions/_7zz"
if [ -f "$ROOT/share/zsh/site-functions/_7zz" ]; then
    install -m 0644 "$ROOT/share/zsh/site-functions/_7zz" \
        "$PREFIX/share/zsh/site-functions/_7zz"
    ok "zsh_completion.install _7zz"
else
    bad "share/zsh/site-functions/_7zz 不存在于 tarball 中"
fi

# bash_completion.install "share/bash-completion/completions/7zz"
if [ -f "$ROOT/share/bash-completion/completions/7zz" ]; then
    install -m 0644 "$ROOT/share/bash-completion/completions/7zz" \
        "$PREFIX/share/bash-completion/completions/7zz"
    ok "bash_completion.install 7zz"
else
    bad "share/bash-completion/completions/7zz 不存在于 tarball 中"
fi

# fish_completion.install "share/fish/vendor_completions.d/7zz.fish"
if [ -f "$ROOT/share/fish/vendor_completions.d/7zz.fish" ]; then
    install -m 0644 "$ROOT/share/fish/vendor_completions.d/7zz.fish" \
        "$PREFIX/share/fish/vendor_completions.d/7zz.fish"
    ok "fish_completion.install 7zz.fish"
else
    bad "share/fish/vendor_completions.d/7zz.fish 不存在于 tarball 中"
fi

# doc.install Dir["share/doc/7zip/*"]
DOCCOUNT=0
for f in "$ROOT"/share/doc/7zip/*; do
    [ -f "$f" ] || continue
    install -m 0644 "$f" "$PREFIX/share/doc/$NAME/$(basename "$f")"
    DOCCOUNT=$((DOCCOUNT + 1))
done
[ "$DOCCOUNT" -gt 0 ] \
    && ok "doc.install 复制了 $DOCCOUNT 个文档" \
    || bad "doc 目录为空"

echo
echo "== 3. 复现 test do 断言 =="
TESTPATH="$(mktemp -d)"
BIN="$PREFIX/bin"

# assert_match version.to_s, shell_output("#{bin}/7zz i")
if "$BIN/7zz" i 2>/dev/null | grep -q "$VERSION"; then
    ok "断言 1: \`7zz i\` 输出包含版本号 $VERSION"
else
    bad "断言 1: \`7zz i\` 未输出版本号 $VERSION"
fi

# (testpath/"hello.txt").write "hello from 7-Zip\n"
printf 'hello from 7-Zip\n' > "$TESTPATH/hello.txt"

# system bin/"7zz", "a", "-t7z", "round.7z", "hello.txt"
( cd "$TESTPATH" && "$BIN/7zz" a -t7z round.7z hello.txt >/dev/null )
if [ -f "$TESTPATH/round.7z" ]; then
    ok "断言 2: assert_path_exists round.7z"
else
    bad "断言 2: round.7z 未生成"
fi

# assert_match "Everything is Ok", shell_output("#{bin}/7zz", "t", "round.7z")
if ( cd "$TESTPATH" && "$BIN/7zz" t round.7z 2>&1 ) | grep -q "Everything is Ok"; then
    ok "断言 3: \`7zz t\` 报告 Everything is Ok"
else
    bad "断言 3: \`7zz t\` 未报告 Everything is Ok"
fi

# assert_match "hello.txt", listing
if ( cd "$TESTPATH" && "$BIN/7zz" l round.7z 2>&1 ) | grep -q "hello.txt"; then
    ok "断言 4: \`7zz l\` 列出 hello.txt"
else
    bad "断言 4: \`7zz l\` 未列出 hello.txt"
fi

# system bin/"7zz", "x", "-y", "round.7z", "-o#{testpath}/out"
( cd "$TESTPATH" && "$BIN/7zz" x -y round.7z "-o$TESTPATH/out" >/dev/null )
# assert_equal "hello from 7-Zip\n", (testpath/"out/hello.txt").read
if [ -f "$TESTPATH/out/hello.txt" ] \
   && [ "$(cat "$TESTPATH/out/hello.txt")" = "hello from 7-Zip" ]; then
    ok "断言 5: 解包往返内容一致"
else
    bad "断言 5: 解包往返内容不一致"
fi

echo
echo "== 4. 舞台树 =="
( cd "$PREFIX" && find . -type f | sort | sed 's/^/  /' )

echo
if [ "$FAIL" -eq 0 ]; then
    echo "结果: 全部通过 (0 项失败)"
else
    echo "结果: $FAIL 项失败" >&2
fi
rm -rf "$PREFIX" "$SRC" "$TESTPATH"
exit "$FAIL"
