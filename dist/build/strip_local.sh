#!/bin/sh
#
# strip_local.sh — 剥离二进制的**局部符号**（`strip -x`）
#
# 为什么单独做成一步：
#   * 它是对上游 makefile 产物的**纯后处理**，不动上游源码、不动上游 makefile，
#     所以「上游升级零成本」这条约束完全不受影响 —— 这是它和
#     `-Os` / `-ffunction-sections` / `-dead_strip` 那类"要改编译选项"的方案的区别。
#   * 只需在**签名之前**做，否则签名失效（三个调用点都在签名前）。
#   * `-x` 只删局部符号，全局/导出符号一个不动 —— appcheck 里基于
#     `nm -gU` 的符号断言因此照旧成立。
#
# 实测收益（2026-09-27，v26.03 之后加了五个编解码器的版本）：
#   主程序       2,069,136 → 1,902,096（−8.0%）
#   lib7z.dylib  2,479,424 → 2,257,872（−8.9%）
#   QL 扩展      1,727,440 → 1,657,648（−4.0%）
#   合计约 −458 KB（全包 −7.1%）
#
# ⚠️ 副作用：发布二进制与上游 `b/m_<arch>/` 产物不再逐字节接近。BUILD.md 里
# 「与上游产物 cmp -l 比对」那条诊断仍然可用（差异会多出符号表区域），但要知道
# 差异里有这一部分。要拿"未剥离"的产物做比对时用 Z7_NO_STRIP=1 重跑构建。
#
# 用法：sh strip_local.sh <二进制路径>
# 环境变量：Z7_NO_STRIP=1 关闭（用于逐字节比对等场合）

set -e

if [ "${Z7_NO_STRIP:-0}" = "1" ]; then
    echo "   strip -x 已按要求跳过（Z7_NO_STRIP=1）"
    exit 0
fi

BIN="$1"
if [ -z "$BIN" ] || [ ! -f "$BIN" ]; then
    echo "strip_local.sh: 用法: sh strip_local.sh <二进制路径>" >&2
    exit 2
fi

if ! command -v strip >/dev/null 2>&1; then
    echo "   无 strip 命令，跳过（不影响功能）"
    exit 0
fi

BEFORE="$(wc -c < "$BIN" | tr -d ' ')"
# 失败不算错误：某些产物（例如已经剥离过的）会报 "no symbols"。
if ! strip -x "$BIN" 2>/dev/null; then
    echo "   $(basename "$BIN"): 无需剥离（或已剥离）"
    exit 0
fi
AFTER="$(wc -c < "$BIN" | tr -d ' ')"
printf '   %-22s %8s -> %8s 字节（省 %s）\n' "$(basename "$BIN")" "$BEFORE" "$AFTER" "$((BEFORE - AFTER))"
