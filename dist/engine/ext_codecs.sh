#!/bin/sh
#
# ext_codecs.sh — 探测外部压缩库（zstd / lz4 / brotli），输出编译与链接标志
#
# 为什么要外部库：上游 7-Zip 26.03 只带 ZstdDecoder（没有编码器），并且完全没有
# lz4 / brotli。本项目约定「上游源码原样保留」，所以这些格式实现在 dist/engine
# 下，算法本身交给成熟的第三方库。
#
# 关键约束：一律链**静态库**（libzstd.a / liblz4.a / libbrotli*.a），
# 这样发行包里不会多出动态库依赖，.app 与 QL 扩展仍是自包含的。
#
# 降级策略：任何一个库缺失，就只把对应格式编译出去（EXT_CODEC_DEFS 里不会有
# 对应的 HAVE_*），构建照常成功，只是少一种格式。这样没有装 Homebrew 的机器
# （以及 CI）不会因为缺库而整体编译失败。
#
# 用法（被其它构建脚本 source，不要单独执行）：
#   . "$HERE/ext_codecs.sh"
#   clang++ $CFLAGS $EXT_CODEC_DEFS $EXT_CODEC_INCS -c Z7ExtCodec.cpp
#   clang++ ... $EXT_CODEC_LIBS -o out
#
# 输出变量：
#   EXT_CODEC_DEFS  形如 "-DZ7_HAVE_ZSTD=1 -DZ7_HAVE_LZ4=1"
#   EXT_CODEC_INCS  形如 "-I/opt/homebrew/opt/zstd/include"
#   EXT_CODEC_LIBS  形如 "/opt/homebrew/opt/zstd/lib/libzstd.a"
#   EXT_CODEC_NAMES 形如 "zstd lz4"（供构建日志打印）

EXT_CODEC_DEFS=""
EXT_CODEC_INCS=""
EXT_CODEC_LIBS=""
EXT_CODEC_NAMES=""

# ⚠️ 本脚本会被 **zsh 与 sh 两种 shell source**（调用方的 shell 说了算），
# 所以绝不能依赖「未加引号的变量会被分词」——zsh 不做这件事，写成
# `for p in $list` 在 zsh 下只会得到一整个词，探测会静默全空（实测踩过：
# zsh 下 EXT_CODEC_NAMES 为空、sh 下正常）。所有候选一律写成**字面量列表**。

# 找某个库的静态库：把所有 .a 逐个作为独立参数传进来（字面量，不靠分词）。
# 成功时把结果放进 _found_libs / _found_incs。
_ext_codec_probe() {
    _libdirs="/opt/homebrew/lib /usr/local/lib"
    for _lib in /opt/homebrew/lib /usr/local/lib; do
        _inc="${_lib%/lib}/include"
        [ -d "$_inc" ] || continue
        [ -d "$_lib" ] || continue

        _missing=0
        for _a in "$@"; do
            [ -f "$_lib/$_a" ] || _missing=1
        done
        [ "$_missing" -eq 0 ] || continue

        _libs=""
        for _a in "$@"; do
            _libs="$_libs $_lib/$_a"
        done
        _found_libs="$_libs"
        _found_incs="$_inc"
        return 0
    done
    return 1
}

# 单个库探测成功后的登记。$1 = 库名
_ext_codec_accept() {
    EXT_CODEC_DEFS="$EXT_CODEC_DEFS -DZ7_HAVE_$(echo "$1" | tr 'a-z' 'A-Z')=1"
    EXT_CODEC_INCS="$EXT_CODEC_INCS -I$_found_incs"
    EXT_CODEC_LIBS="$EXT_CODEC_LIBS $_found_libs"
    EXT_CODEC_NAMES="$EXT_CODEC_NAMES $1"
}

_found_libs=""
_found_incs=""
if _ext_codec_probe libzstd.a; then _ext_codec_accept zstd; fi

_found_libs=""
_found_incs=""
if _ext_codec_probe liblz4.a; then _ext_codec_accept lz4; fi

# brotli 的静态库名有两种写法：Homebrew 用 libbrotlidec-static.a，
# 自行编译/其它发行版常用 libbrotlidec.a。两种都试。
_found_libs=""
_found_incs=""
if _ext_codec_probe libbrotlidec-static.a libbrotlienc-static.a libbrotlicommon-static.a; then
    _ext_codec_accept brotli
else
    _found_libs=""
    _found_incs=""
    if _ext_codec_probe libbrotlidec.a libbrotlienc.a libbrotlicommon.a; then
        _ext_codec_accept brotli
    fi
fi

# 去掉前导空格，避免空值时在命令行里留下多余参数
EXT_CODEC_DEFS="${EXT_CODEC_DEFS# }"
EXT_CODEC_INCS="${EXT_CODEC_INCS# }"
EXT_CODEC_LIBS="${EXT_CODEC_LIBS# }"
EXT_CODEC_NAMES="${EXT_CODEC_NAMES# }"
