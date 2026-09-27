#!/bin/sh
#
# apply_upstream_patch.sh — 把本移植的 macOS 补丁施加到上游源码树上
#
# 为什么需要它（先说清事实）：
#   本仓库的上游源码**不是**逐字节原样的上游发布包。除了官方文件之外，还带着
#   一份 10 个文件的补丁（`upstream-macos.patch`）：
#
#     CPP/Common/StringConvert.cpp                 非 UTF-8 字节串按 GB18030 解码
#                                                  （中文 Windows 压出来的 zip 名字全靠它）
#     CPP/7zip/UI/Common/MacOsNative.{h,cpp}        新增文件：xattr / 名字规范化
#     CPP/7zip/UI/Common/ExtractingFilePath.cpp     解压时按 NFD 规范化名字
#     CPP/7zip/UI/Common/ArchiveExtractCallback.{h,cpp}
#                                                  解压后传播隔离属性（quarantine）
#     CPP/7zip/7zip_gcc.mak                         MacOsNative.o 编译规则
#     CPP/7zip/Bundles/Alone2/makefile.gcc          MacOsNative.o 加入目标
#     CPP/7zip/var_mac_arm64.mak / var_mac_x64.mak  平台构建变量
#
#   这些补丁是**承重的**：少了它们，中文 Windows 归档的文件名会变乱码、
#   解出的树与 macOS 原生树的 Unicode 形式不一致（git/rsync 里会出现"看起来
#   一样的两个名字"）、隔离属性也不会传播。升级上游时若忘记重新施加，
#   构建**照样成功**，只是行为悄悄退化 —— 所以升级脚本会自动施加，构建脚本
#   会在开工前先校验一次。
#
# 用法：
#   sh dist/build/apply_upstream_patch.sh <上游源码目录>            # 施加
#   sh dist/build/apply_upstream_patch.sh <上游源码目录> --check    # 只校验（不落盘）
#
# 退出码：0 = 成功/已正确施加；1 = 失败（--check 时表示"没打上"）

set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
PATCH="$HERE/upstream-macos.patch"

SRC=""
CHECK=0
for a in "$@"; do
    case "$a" in
        --check) CHECK=1 ;;
        -*) echo "未知选项：$a" >&2; exit 2 ;;
        *) SRC="$a" ;;
    esac
done

if [ -z "$SRC" ] || [ ! -d "$SRC" ]; then
    echo "用法: sh apply_upstream_patch.sh <上游源码目录> [--check]" >&2
    exit 2
fi
if [ ! -f "$PATCH" ]; then
    echo "找不到补丁文件：$PATCH" >&2
    exit 1
fi
if [ ! -f "$SRC/C/7zVersion.h" ]; then
    echo "目标看起来不是上游源码目录（缺少 C/7zVersion.h）：$SRC" >&2
    exit 1
fi

# 判断"是否已经施加"：逐个检查每个被打补丁的文件里是否存在**只属于本移植**的标记。
#
# ⚠️ 不要用 `patch -R --dry-run` 当判据：实测 macOS 自带的 patch 在**未打补丁**的
# 树上也会静默返回 0（会打印 "No such line N in input file, ignoring" 然后仍然
# 成功退出），拿它做检查会给出"已打补丁"的假阳性 —— 正是这个假阳性让升级后的
# 缺补丁状态被漏过去。
#
# 标记全部是本移植自己写的标识符或注释，上游怎么改版本都不会自然出现这些字符串。
# 十个文件各取一个，避免"只打了半个补丁"这种情况被判成通过。
check_markers() {
    S="$1"
    grep -q -- 'MacOsNative.o:'            "$S/CPP/7zip/7zip_gcc.mak" || return 1
    grep -q -- 'MacOsNative.o'             "$S/CPP/7zip/Bundles/Alone2/makefile.gcc" || return 1
    grep -q -- 'MacOsNative.h'             "$S/CPP/7zip/UI/Common/ArchiveExtractCallback.cpp" || return 1
    grep -q -- '_mac_Quarantine'           "$S/CPP/7zip/UI/Common/ArchiveExtractCallback.h" || return 1
    grep -q -- 'MacOs_NormalizeName_NFD'   "$S/CPP/7zip/UI/Common/ExtractingFilePath.cpp" || return 1
    grep -q -- 'MacOs_NormalizeName_NFD'   "$S/CPP/7zip/UI/Common/MacOsNative.cpp" || return 1
    grep -q -- 'MacOs_NormalizeName_NFD'   "$S/CPP/7zip/UI/Common/MacOsNative.h" || return 1
    grep -q -- 'macOS native semantic'     "$S/CPP/7zip/var_mac_arm64.mak" || return 1
    grep -q -- 'macOS native semantic'     "$S/CPP/7zip/var_mac_x64.mak" || return 1
    grep -q -- 'ConvertFromGB18030_Apple'  "$S/CPP/Common/StringConvert.cpp" || return 1
    return 0
}

if check_markers "$SRC"; then
    if [ "$CHECK" = "1" ]; then
        echo "补丁已正确施加：$(basename "$SRC")"
        exit 0
    fi
    echo "   补丁已经施加过，无需重复（$(basename "$SRC")）"
    exit 0
fi

if [ "$CHECK" = "1" ]; then
    echo "上游源码缺少本移植的 macOS 补丁：$SRC" >&2
    echo "  请先运行： sh dist/build/apply_upstream_patch.sh '$SRC'" >&2
    exit 1
fi

echo "   施加 macOS 补丁 -> $(basename "$SRC")"
# --forward：遇到"已打过的 hunk"就跳过而不是反问；--batch：绝不进入交互。
if ! patch -p1 -d "$SRC" --forward --batch --silent < "$PATCH"; then
    echo "补丁施加过程中有 hunk 失败（上游可能改动了这些位置）。" >&2
    echo "  失败明细：patch -p1 -d '$SRC' --forward --batch < $PATCH" >&2
    echo "  补丁文件：$PATCH" >&2
    exit 1
fi

if check_markers "$SRC"; then
    echo "   已施加并校验通过（10 个文件的标记齐全）"
else
    echo "施加后有标记缺失 —— 结果不符合预期，请人工核对。" >&2
    echo "  失败明细：patch -p1 -d '$SRC' --forward --batch < $PATCH" >&2
    exit 1
fi
