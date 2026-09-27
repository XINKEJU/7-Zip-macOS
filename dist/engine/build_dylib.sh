#!/bin/sh
#
# build_dylib.sh — 由上游源码构建 7z.dylib 引擎动态库（技术方案 §3.3 表 4）
#
# 使用 Format7zF Bundle 构建全部格式的共享库，arm64 单架构（Apple Silicon）。
# 该库是整个内嵌路线的引擎核心，也是 LGPL 合规中"可被用户替换的那一个库"。
#
# 此前这里是 arm64 + x86_64 双架构 lipo 合成；2026-09-24 起放弃 Intel 支持，
# 理由与恢复方式见仓库 Makefile 文件头。
#
# 产出：dist/lib/lib7z.dylib（install_name = @rpath/7z.dylib）
#
# 用法：sh build_dylib.sh [源码根目录]

set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
DIST="$(cd "$HERE/.." && pwd)"
SRC="${1:-$(sh "$DIST/build/upstream_dir.sh")}"
SRC="$(cd "$SRC" && pwd)"

BUNDLE="$SRC/CPP/7zip/Bundles/Format7zF"
OUTDIR="$DIST/lib"
OUT="$OUTDIR/lib7z.dylib"

if [ ! -d "$BUNDLE" ]; then
    echo "找不到 Format7zF Bundle: $BUNDLE" >&2
    exit 1
fi

# ⚠️ 上游源码必须已经打好本移植的 macOS 补丁（非 UTF-8 名字按 GB18030 解码、
# 解压时按 NFD 规范化、隔离属性传播）。升级上游后最容易忘的就是这一步，
# 而**忘了的后果是构建照样成功、行为悄悄退化** —— 所以在这里先挡一道。
# 详见 dist/build/apply_upstream_patch.sh 的文件头。
sh "$DIST/build/apply_upstream_patch.sh" "$SRC" --check || exit 1

echo "=== 源码根目录: $SRC"
echo "=== Bundle:      $BUNDLE"
mkdir -p "$OUTDIR"

cd "$BUNDLE"
# 不使用 rm -rf b 做清理：一是破坏性批量删除风险高（且被安全钩子拦截），
# 二是没必要。改用 make -B 强制全部目标重编译，效果等价且不删任何文件。
# 若需彻底清理，请手动执行：make -f ../../cmpl_mac_arm64.mak clean

# 必须显式声明部署目标：上游 cmpl_mac_*.mak 只设置 -arch，不含最低系统版本，
# 于是 clang 会采用当前 SDK 的默认值（本机为 26.1），产出 minos=26.1 的 dylib。
# 那样的库在 macOS 26.1 以下的系统上会被 dyld 直接拒绝加载，
# 与本移植"支持 macOS 11.0+"的目标冲突（内嵌的 7zz 正是 minos 11.0）。
export MACOSX_DEPLOYMENT_TARGET=11.0
echo "=== 部署目标: MACOSX_DEPLOYMENT_TARGET=$MACOSX_DEPLOYMENT_TARGET"

echo "== 编译 arm64 =="
make -B -j"$(sysctl -n hw.ncpu)" -f ../../cmpl_mac_arm64.mak > "$DIST/engine/.build_dylib_arm64.log" 2>&1 \
    || { tail -30 "$DIST/engine/.build_dylib_arm64.log" >&2; exit 1; }
ls -la b/m_arm64/7z.so

echo "== 取出编译产物 =="
# 单架构，无需 lipo（lipo 对单输入也只是复制）。
cp -f b/m_arm64/7z.so "$OUT"
# install_name 必须与文件名一致：dyld 按 "@rpath/<install_name 的末段>" 查找，
# 若写成 @rpath/7z.dylib 而文件叫 lib7z.dylib，加载时会直接报
# "Library not loaded: @rpath/7z.dylib"。
install_name_tool -id @rpath/lib7z.dylib "$OUT"

# 剥离局部符号（−8.9%）。必须在上面的 install_name_tool 之后、任何签名之前；
# 只删局部符号，导出符号不动。详见 dist/build/strip_local.sh 的文件头。
sh "$DIST/build/strip_local.sh" "$OUT"

echo "== 结果 =="
lipo -archs "$OUT" | sed 's/^/   架构: /'
otool -D "$OUT" | tail -n +2 | sed 's/^/   install_name: /'
nm -gU "$OUT" | grep -E "_CreateObject|_GetNumberOfFormats|_GetHandlerProperty2" | sed 's/^/   /'
ls -la "$OUT"
