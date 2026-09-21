#!/bin/sh
#
# build_engine.sh — 构建 7-Zip 引擎内嵌桥接层静态库（技术方案 §3.3 / §4.1）
#
# 产出：
#   dist/lib/lib7zbridge.a      C++ 桥接层 + 上游规定的客户端辅助对象（通用）
#   dist/lib/lib7zbridgeobjc.a  Objective-C++ 适配层（通用，依赖 Foundation）
#
# 两个库有意分离：纯 C++ 的桥接层可被命令行测试程序单独链接，
# 不会把 Foundation/AppKit 依赖带给非 GUI 调用方。
#
# 依赖：
#   dist/lib/lib7z.dylib     Format7zF 编出的引擎动态库（由 build_dylib.sh 生成）
#
# 说明：
#   客户端需要自行编译的 7-Zip 源文件清单取自上游示例
#   CPP/7zip/UI/Client7z/makefile.gcc（COMMON_OBJS / WIN_OBJS / 7ZIP_COMMON_OBJS），
#   另加 MultiOutStream.cpp 与 System.cpp 以支持分卷输出。
#
# 用法：sh build_engine.sh [源码根目录]

set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
DIST="$(cd "$HERE/.." && pwd)"
SRC="${1:-$DIST/../7z2603-src}"
SRC="$(cd "$SRC" && pwd)"

OUT="$DIST/lib"
BUILD="$DIST/engine/.build"
TARGET="$OUT/lib7zbridge.a"
TARGET_OBJC="$OUT/lib7zbridgeobjc.a"

INC="-I$SRC/CPP -I$SRC/C"
MINVER="-mmacosx-version-min=11.0"
CFLAGS_BASE="-O2 -DNDEBUG -D_REENTRANT -D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE -fPIC -w $MINVER"
CFLAGS="$CFLAGS_BASE $INC"
CC_BIN_C=clang
CC_BIN_CXX=clang++

# 上游 makefile.gcc 中客户端需自行编译的源文件（路径相对源码根目录）
HELPERS="
C/Alloc.c
CPP/Common/IntToString.cpp
CPP/Common/MyString.cpp
CPP/Common/MyVector.cpp
CPP/Common/NewHandler.cpp
CPP/Common/StringConvert.cpp
CPP/Common/StringToInt.cpp
CPP/Common/UTFConvert.cpp
CPP/Common/Wildcard.cpp
CPP/Windows/DLL.cpp
CPP/Windows/FileDir.cpp
CPP/Windows/FileFind.cpp
CPP/Windows/FileIO.cpp
CPP/Windows/FileName.cpp
CPP/Windows/PropVariant.cpp
CPP/Windows/PropVariantConv.cpp
CPP/Windows/PropVariantUtils.cpp
CPP/Windows/TimeUtils.cpp
CPP/Common/MyWindows.cpp
CPP/Windows/System.cpp
CPP/7zip/Common/FileStreams.cpp
CPP/7zip/Common/MultiOutStream.cpp
"

echo "=== 源码根目录: $SRC"
echo "=== 输出目录:   $OUT"
mkdir -p "$BUILD" "$OUT"

# 不预先删除产物：
#   * lipo -create 会直接覆盖已存在的输出文件；
#   * ar 改为"先写临时文件再 mv 覆盖"，既避免在已存在的归档里残留陈旧成员，
#     也不必执行任何批量删除（批量删除会被安全钩子拦截并静默中止构建，
#     表现出来是"改了脚本但产物没变"，非常难查）。
ARCHS="arm64 x86_64"
BUILT_ARCHS=""
BUILT_ARCHS_OBJC=""

for ARCH in $ARCHS; do
    ADIR="$BUILD/$ARCH"
    mkdir -p "$ADIR"
    OBJS=""

    echo "== 编译 $ARCH =="
    for REL in $HELPERS; do
        SRC_FILE="$SRC/$REL"
        if [ ! -f "$SRC_FILE" ]; then
            echo "   缺少源文件: $SRC_FILE" >&2
            exit 1
        fi
        OBJ="$ADIR/$(echo "$REL" | tr '/' '_' | sed 's/\.c\(pp\)\{0,1\}$/.o/')"
        case "$REL" in
            *.c) $CC_BIN_C $CFLAGS -arch "$ARCH" -c "$SRC_FILE" -o "$OBJ" ;;
            *)   $CC_BIN_CXX $CFLAGS -arch "$ARCH" -std=c++11 -c "$SRC_FILE" -o "$OBJ" ;;
        esac
        OBJS="$OBJS $OBJ"
    done

    # 桥接层本体
    OBJ="$ADIR/SevenZipEngine.o"
    clang++ $CFLAGS -arch "$ARCH" -std=c++11 -c "$HERE/SevenZipEngine.cpp" -o "$OBJ"
    OBJS="$OBJS $OBJ"

    ARCH_LIB="$ADIR/lib7zbridge.a"
    ar rcs "$ARCH_LIB.tmp" $OBJS
    mv -f "$ARCH_LIB.tmp" "$ARCH_LIB"
    echo "   -> $ARCH_LIB ($(wc -c < "$ARCH_LIB" | tr -d ' ') 字节)"
    BUILT_ARCHS="$BUILT_ARCHS $ARCH_LIB"

    # Objective-C++ 适配层（独立库，见文件头说明）
    OBJC_OBJ="$ADIR/SevenZipEngineObjC.o"
    clang++ $CFLAGS -arch "$ARCH" -std=c++11 -x objective-c++ -fobjc-arc \
            -fmodules -I"$HERE" -c "$HERE/SevenZipEngineObjC.mm" -o "$OBJC_OBJ"
    ARCH_LIB_OBJC="$ADIR/lib7zbridgeobjc.a"
    ar rcs "$ARCH_LIB_OBJC.tmp" "$OBJC_OBJ"
    mv -f "$ARCH_LIB_OBJC.tmp" "$ARCH_LIB_OBJC"
    echo "   -> $ARCH_LIB_OBJC ($(wc -c < "$ARCH_LIB_OBJC" | tr -d ' ') 字节)"
    BUILT_ARCHS_OBJC="$BUILT_ARCHS_OBJC $ARCH_LIB_OBJC"
done

echo "== 合并通用二进制 =="
lipo -create $BUILT_ARCHS -output "$TARGET"
echo "   -> $TARGET"
lipo -archs "$TARGET" | sed 's/^/   架构: /'

lipo -create $BUILT_ARCHS_OBJC -output "$TARGET_OBJC"
echo "   -> $TARGET_OBJC"
lipo -archs "$TARGET_OBJC" | sed 's/^/   架构: /'

ls -la "$TARGET" "$TARGET_OBJC"

echo
echo "完成。"
