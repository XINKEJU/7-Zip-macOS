#!/bin/sh
#
# build_test.sh — 构建桥接层验收测试程序 engine_test（arm64）
#
# 依赖：
#   dist/lib/lib7zbridge.a   桥接层（build_engine.sh 产出）
#   dist/lib/lib7z.dylib     引擎动态库（build_dylib.sh 产出）
#
# 测试程序通过 @rpath/7z.dylib 引用引擎，运行期 rpath 指向 dist/lib，
# 因此源码树内可直接执行，无需安装。
#
# 用法：sh build_test.sh

set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
DIST="$(cd "$HERE/.." && pwd)"
LIB="$DIST/lib"

for f in "$LIB/lib7zbridge.a" "$LIB/lib7z.dylib" "$HERE/engine_test.cpp"; do
    if [ ! -e "$f" ]; then
        echo "缺少依赖：$f" >&2
        echo "  请先运行 dist/engine/build_dylib.sh 与 dist/engine/build_engine.sh" >&2
        exit 1
    fi
done

# ⚠️ 桥接层源码可能比 lib7zbridge.a 新。`make test` 刻意不依赖 `bridge`（那会连带
# 全量重编上游引擎，太慢），于是「改了 C++ 却在测旧库」会静默发生 —— 本次踩过一次：
# 测试报告的失败现象与刚改的代码完全对不上。这里做一个廉价的新鲜度检查。
BRIDGE_SRC="$(find "$DIST/engine" -maxdepth 1 \
        \( -name '*.cpp' -o -name '*.h' -o -name '*.mm' -o -name '*.sh' \) \
        -newer "$LIB/lib7zbridge.a" -print -quit 2>/dev/null)"
if [ -n "$BRIDGE_SRC" ]; then
    echo "  桥接层源码（$(basename "$BRIDGE_SRC")）比产物新，先重建"
    BLOG="${TMPDIR:-/tmp}/z7bridge_build.log"
    if ! sh "$DIST/engine/build_engine.sh" >"$BLOG" 2>&1; then
        echo "  重建桥接层失败，日志：$BLOG" >&2
        cat "$BLOG" >&2
        exit 1
    fi
    echo "  已重建 $LIB/lib7zbridge.a"
fi

# 外部压缩库（zstd / lz4 / brotli）的静态库：桥接层引用了它们的符号，
# 缺了会链接失败。库不存在时探测结果为空，链接照旧（对应格式已被编译出去）。
. "$DIST/engine/ext_codecs.sh"

export MACOSX_DEPLOYMENT_TARGET=11.0

# 只构建 arm64：测试程序与它链接的桥接层/引擎必须同架构，否则链接即失败。
clang++ -std=c++11 -O2 -Wall -w \
    -arch arm64 -mmacosx-version-min=11.0 \
    -I"$DIST/engine" \
    -o "$HERE/engine_test" \
    "$HERE/engine_test.cpp" \
    "$LIB/lib7zbridge.a" \
    $EXT_CODEC_LIBS \
    -L"$LIB" -l7z \
    -Wl,-rpath,"$LIB" \
    -framework CoreFoundation
chmod 755 "$HERE/engine_test"

echo "   -> $HERE/engine_test"
lipo -archs "$HERE/engine_test" | sed 's/^/   架构: /'
