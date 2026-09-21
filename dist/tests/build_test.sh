#!/bin/sh
#
# build_test.sh — 构建桥接层验收测试程序 engine_test（通用二进制）
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
BUILD="$HERE/.build"
LIB="$DIST/lib"

for f in "$LIB/lib7zbridge.a" "$LIB/lib7z.dylib" "$HERE/engine_test.cpp"; do
    if [ ! -e "$f" ]; then
        echo "缺少依赖：$f" >&2
        echo "  请先运行 dist/engine/build_dylib.sh 与 dist/engine/build_engine.sh" >&2
        exit 1
    fi
done

mkdir -p "$BUILD"
export MACOSX_DEPLOYMENT_TARGET=11.0

for ARCH in arm64 x86_64; do
    clang++ -std=c++11 -O2 -Wall -w \
        -arch "$ARCH" -mmacosx-version-min=11.0 \
        -I"$DIST/engine" \
        -o "$BUILD/engine_test-$ARCH" \
        "$HERE/engine_test.cpp" \
        "$LIB/lib7zbridge.a" \
        -L"$LIB" -l7z \
        -Wl,-rpath,"$LIB" \
        -framework CoreFoundation
    printf '   %-8s %s bytes\n' "$ARCH" "$(stat -f%z "$BUILD/engine_test-$ARCH")"
done

lipo -create "$BUILD/engine_test-arm64" "$BUILD/engine_test-x86_64" \
     -output "$HERE/engine_test"
chmod 755 "$HERE/engine_test"

echo "   -> $HERE/engine_test"
lipo -archs "$HERE/engine_test" | sed 's/^/   架构: /'
