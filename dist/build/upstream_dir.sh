#!/bin/sh
#
# upstream_dir.sh — 打印当前使用的**上游源码目录**（绝对路径，仅这一行到 stdout）
#
# 为什么要单独一个脚本：
#   上游目录名里带版本号（`7z2603-src`），而 Makefile 与四个构建/打包脚本都要
#   引用它。以前这个字符串被硬编码在 5 个文件里 —— 升级上游就得同步改 5 处，
#   漏一处的症状是「构建时提示找不到某个上游文件」，与真正的升级动作很难联想到
#   一起。解析集中到这一处之后，升级只由 upgrade_upstream.sh 负责。
#
# 解析顺序：
#   1. 环境变量 Z7_SRC —— 显式指定，升级脚本与 CI 用它；指向不存在的目录即报错，
#      绝不静默回退（否则「以为在测新版、其实还是旧版」）。
#   2. 仓库根下**版本号最高**的 7zXXYY-src/。版本号从 C/7zVersion.h 的
#      MY_VERSION_NUMBERS 读，不靠目录名字符串比较。
#
# 诊断信息一律走 stderr：调用方（$(shell …)）只把 stdout 当路径用。
#
# 用法：sh upstream_dir.sh

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

if [ -n "${Z7_SRC:-}" ]; then
    if [ ! -d "$Z7_SRC" ] || [ ! -f "$Z7_SRC/C/7zVersion.h" ]; then
        echo "Z7_SRC 不是有效的上游源码目录（缺少 C/7zVersion.h）：$Z7_SRC" >&2
        exit 1
    fi
    (cd "$Z7_SRC" && pwd)
    exit 0
fi

BEST=""
BESTVER=0
COUNT=0
for d in "$ROOT"/7z*-src; do
    [ -d "$d" ] || continue
    VH="$d/C/7zVersion.h"
    [ -f "$VH" ] || continue
    COUNT=$((COUNT + 1))
    # MY_VERSION_NUMBERS "26.03"  ->  2603
    V="$(sed -n 's/.*MY_VERSION_NUMBERS[^"]*"\([0-9][0-9]*\)\.\([0-9][0-9]*\)".*/\1\2/p' "$VH" | head -1)"
    [ -n "$V" ] || continue
    if [ "$V" -gt "$BESTVER" ]; then
        BESTVER="$V"
        BEST="$d"
    fi
done

if [ -z "$BEST" ]; then
    echo "找不到上游源码目录（$ROOT/7zXXXX-src/C/7zVersion.h）" >&2
    echo "  首次获取可运行： sh dist/build/upgrade_upstream.sh <版本号>   例如 26.03" >&2
    exit 1
fi

if [ "$COUNT" -gt 1 ]; then
    echo "注意：仓库里有 $COUNT 个上游源码目录，选用版本最高的 $(basename "$BEST")。" >&2
    echo "      退役旧的请用 git rm -r（见 upgrade_upstream.sh 的提示）。" >&2
fi

(cd "$BEST" && pwd)
