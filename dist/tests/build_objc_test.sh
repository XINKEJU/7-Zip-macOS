#!/bin/sh
#
# build_objc_test.sh — 构建 Objective-C 适配层验收测试（objc_test）。
#
# 与 build_test.sh 分开的原因：本程序走 ObjC++ 层，需要同时链接
#   lib7zbridgeobjc.a（ObjC 适配层）与 lib7zbridge.a（C++ 桥接层），
# 并且必须开 ARC 与 modules。把这两套链接参数混在一起容易出错，
# 故各自独立脚本、独立二进制。
#
# 用法：sh build_objc_test.sh

set -e

DIST="$(cd "$(dirname "$0")/.." && pwd)"
HERE="$DIST/tests"
ENGINE="$DIST/engine"
LIB="$DIST/lib"

if [ ! -f "$LIB/lib7zbridge.a" ] || [ ! -f "$LIB/lib7zbridgeobjc.a" ]; then
    echo "缺少桥接层静态库，请先运行 sh dist/engine/build_engine.sh" >&2
    exit 2
fi
if [ ! -f "$LIB/lib7z.dylib" ]; then
    echo "缺少引擎动态库 $LIB/lib7z.dylib，请先运行 sh dist/engine/build_engine.sh" >&2
    exit 2
fi

build_arch() {
    arch="$1"
    out="$HERE/objc_test"
    clang -fobjc-arc -fmodules -Wall -O2 \
          -arch "$arch" -mmacosx-version-min=11.0 \
          -I"$ENGINE" -I"$LIB" \
          -o "$out" "$HERE/objc_test.m" \
          "$LIB/lib7zbridgeobjc.a" "$LIB/lib7zbridge.a" \
          -L"$LIB" -l7z -lc++ \
          -Wl,-rpath,"$LIB" \
          -framework Foundation -framework CoreFoundation
    printf "   %-8s %s bytes\n" "$arch" "$(stat -f%z "$out")"
}

# 只构建 arm64：必须与所链接的桥接层/引擎同架构。
echo "== 编译 arm64 =="
build_arch arm64
lipo -archs "$HERE/objc_test" | sed 's/^/   架构: /'
echo "完成：$HERE/objc_test"
