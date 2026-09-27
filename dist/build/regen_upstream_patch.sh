#!/bin/sh
#
# regen_upstream_patch.sh — 由「官方原版源码」与「当前工作树」重新生成
#                            dist/build/upstream-macos.patch
#
# 为什么需要它：
#   本仓库的上游源码是「官方原版 + 10 个文件的 macOS 补丁」。补丁文件与源码树
#   必须始终一致，否则两者会悄悄分叉 —— 树改了而补丁没跟上，下次升级上游时
#   `apply_upstream_patch.sh` 施加的是旧改动，而 `--check` 的标记仍在，**看不出问题**。
#   所以在动手修改上游文件（例如给被改文件补 LGPL 要求的「已修改」声明）之后，
#   必须跑一次本脚本。
#
# 用法：
#   sh dist/build/regen_upstream_patch.sh <官方原版源码目录> [<工作树>]
#
#   官方原版可取：
#     tar -xJf 7z2603-src.tar.xz -C /tmp/z7pristine && \
#       sh dist/build/regen_upstream_patch.sh /tmp/z7pristine
#
#   工作树缺省用 upstream_dir.sh 解析（优先 $Z7_SRC）。
#
# 可复现性：两侧文件 mtime 会被统一固定（见下），因此同一棵树无论何时重生成
#   都得到逐字节相同的补丁文件 —— 否则每次都会因工作树 mtime 变动产生全量 diff 噪声。

set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUT="$HERE/upstream-macos.patch"

PRISTINE="$1"
TREE="$2"

if [ -z "$PRISTINE" ] || [ ! -d "$PRISTINE" ]; then
    echo "用法: sh regen_upstream_patch.sh <官方原版源码目录> [<工作树>]" >&2
    exit 2
fi
if [ ! -f "$PRISTINE/C/7zVersion.h" ]; then
    echo "第一个参数看起来不是上游源码目录（缺 C/7zVersion.h）：$PRISTINE" >&2
    exit 2
fi

if [ -z "$TREE" ]; then
    TREE="$(sh "$HERE/upstream_dir.sh")"
fi
if [ ! -f "$TREE/C/7zVersion.h" ]; then
    echo "工作树看起来不是上游源码目录（缺 C/7zVersion.h）：$TREE" >&2
    exit 2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT INT TERM

# 只搬运源码，排除上游的编译产物目录 b/ 与 macOS 垃圾文件。
mkdir -p "$WORK/a" "$WORK/b"
( cd "$PRISTINE" && tar cf - --exclude=b --exclude=.DS_Store --exclude=._* . ) | ( cd "$WORK/a" && tar xf - )
( cd "$TREE"     && tar cf - --exclude=b --exclude=.DS_Store --exclude=._* . ) | ( cd "$WORK/b" && tar xf - )

# 固定时间戳：让 ---/+++ 头部两侧一致，补丁文件因此可逐字节复现。
# 新增文件在 a/ 侧不存在，diff 仍会按惯例标成 1970-01-01。
find "$WORK/a" "$WORK/b" -exec touch -t 202601010000 {} +

# diff 有差异时返回 1；用 if 吸收，避免 set -e 提前退出。
if ( cd "$WORK" && diff -ruN a b ) > "$OUT"; then
    echo "警告：原版与工作树没有任何差异 —— 补丁为空。" >&2
    exit 1
fi

echo "==> 已重生成 $OUT"
echo "    原版：$PRISTINE"
echo "    工作树：$TREE"
printf '    文件清单（%s 个）：\n' "$(grep -c '^diff -ruN a/' "$OUT")"
grep '^diff -ruN a/' "$OUT" | sed 's|^diff -ruN a/||;s| b/.*||' | sed 's/^/       /'

# 自校验：新补丁必须能在**干净的原版树**上施加，且施完后与工作树逐字节一致。
VERIFY="$WORK/verify"
mkdir -p "$VERIFY"
( cd "$PRISTINE" && tar cf - --exclude=b --exclude=.DS_Store --exclude=._* . ) | ( cd "$VERIFY" && tar xf - )
if ! patch -p1 -d "$VERIFY" --forward --batch --silent < "$OUT"; then
    echo "自校验失败：新补丁无法施加到干净的原版树上。" >&2
    exit 1
fi
# 只比对源码，忽略时间戳；b/ 与垃圾文件两侧都不参与。
if diff -rq -x b -x '.DS_Store' -x '._*' "$VERIFY" "$TREE" > "$WORK/diffout" 2>&1; then
    echo "    自校验通过：干净原版 + 新补丁 == 当前工作树（逐字节一致）"
else
    echo "自校验失败：施加补丁后的树与工作树不一致 ——" >&2
    cat "$WORK/diffout" >&2
    exit 1
fi

# 工作树的标记必须齐全（防止补丁只覆盖了一半）。
sh "$HERE/apply_upstream_patch.sh" "$TREE" --check
