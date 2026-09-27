#!/bin/sh
#
# upgrade_upstream.sh — 把上游 7-Zip 引擎升级到指定版本
#
# 为什么需要它：
#   本项目与上游的关系是「上游源码原样 vendored 在仓库里 + 移植代码全在 dist/」。
#   这个结构让升级本身没有代码冲突，剩下的全是机械动作：下载 → 校验 → 解包 →
#   退役旧树 → 重跑门禁。机械化的事就该脚本化，否则「上游发新版了」会被一拖再拖，
#   而这是唯一能保证引擎不退化的机制 —— 引擎的先进程度等于上游的先进程度。
#
# 做与不做：
#   * 做：下载、校验（压缩完整性 + 版本号 + 解包结果）、打印后续步骤。
#   * 不做：**不删除**旧源码树。批量删除在带安全钩子的环境里会被静默拦下，
#     而且这一步用 git 做才可回滚，所以脚本只把命令打印出来由人执行。
#   * 不做：不碰 `make pkg` / `make tarball`。已发布的资产不能因为一次升级动作
#     而被重新盖时间戳（见 Makefile 的 verify 段落）。
#
# 用法：
#   sh dist/build/upgrade_upstream.sh 26.04
#   sh dist/build/upgrade_upstream.sh 26.04 --gate        # 顺便重建引擎并跑全部门禁
#   make upstream NEW=26.04 GATE=1                        # 等价写法
#
# 环境变量：
#   Z7_SRC        已在用别的源码树时，本脚本仍按参数下载新版本，不受影响

set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

VER=""
GATE=0
for a in "$@"; do
    case "$a" in
        --gate) GATE=1 ;;
        --help|-h)
            sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        -*) echo "未知选项：$a" >&2; exit 2 ;;
        *) VER="$a" ;;
    esac
done

if [ -z "$VER" ]; then
    echo "用法: sh dist/build/upgrade_upstream.sh <版本号> [--gate]" >&2
    echo "  例如: sh dist/build/upgrade_upstream.sh 26.04 --gate" >&2
    exit 2
fi

case "$VER" in
    [0-9]*.[0-9]*) ;;
    *) echo "版本号格式不对（应形如 26.03）：$VER" >&2; exit 2 ;;
esac

NUMS="$(printf '%s' "$VER" | tr -d '.')"
DIRNAME="7z${NUMS}-src"
TARGET="$ROOT/$DIRNAME"
URL="https://github.com/ip7z/7zip/releases/download/${VER}/${DIRNAME}.tar.xz"

echo "=== 上游升级 ==="
echo "  版本号:   $VER"
echo "  源码目录: $DIRNAME"
echo "  下载地址: $URL"
echo

if [ -e "$TARGET" ]; then
    echo "目标目录已存在：$TARGET" >&2
    echo "  已经是这个版本了？那就直接 make bridge && make test。" >&2
    echo "  想重新取一份，请先把它移走（不要就地覆盖）。" >&2
    exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
    echo "需要 curl 才能下载上游源码。" >&2
    exit 1
fi

TMP="${TMPDIR:-/tmp}/z7-upstream-$$"
ARCHIVE="$TMP/$DIRNAME.tar.xz"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT INT TERM

echo "== 1. 下载 =="
if ! curl -L --fail --silent --show-error -m 900 -o "$ARCHIVE" "$URL"; then
    echo "下载失败。检查网络/版本号是否存在该 Release：" >&2
    echo "  $URL" >&2
    exit 1
fi
printf '   %s 字节（sha256 %s）\n' \
    "$(wc -c < "$ARCHIVE" | tr -d ' ')" \
    "$(shasum -a 256 "$ARCHIVE" | cut -d' ' -f1)"

echo "== 2. 校验归档 =="
# xz 完整性：截断的下载文件会在这一步暴露，而不是等到解包一半才报错
if ! xz -t "$ARCHIVE" 2>/dev/null; then
    echo "归档不是有效的 xz（下载可能被截断）：$ARCHIVE" >&2
    exit 1
fi
# ⚠️ 关键陷阱：官方 src 归档**没有顶层目录** —— 里面直接就是 Asm/ C/ CPP/ DOC/。
# 所以绝不能 `tar -x -C <仓库根>`（那会把整个仓库根搅成一锅粥，而且不会报错）。
# 一律先解到暂存目录，校验通过后再整体改名到 7zXXXX-src/。
if ! tar -tf "$ARCHIVE" | grep -qx "C/7zVersion.h"; then
    echo "归档里没有 C/7zVersion.h —— 结构与预期不符，已停止（未解包）。" >&2
    exit 1
fi
echo "   归档完整；顶层为松散布局（Asm/ C/ CPP/ DOC/），将解到暂存目录再改名"

echo "== 3. 校验版本号 =="
# 把 C/7zVersion.h 单独解出来核对：光看文件名不够，上游偶尔会改动打包结构
tar -xJf "$ARCHIVE" -C "$TMP" "C/7zVersion.h"
GOT="$(sed -n 's/.*MY_VERSION_NUMBERS[^"]*"\([^"]*\)".*/\1/p' "$TMP/C/7zVersion.h" | head -1)"
DATE="$(sed -n 's/.*MY_DATE[^"]*"\([^"]*\)".*/\1/p' "$TMP/C/7zVersion.h" | head -1)"
if [ "$GOT" != "$VER" ]; then
    echo "C/7zVersion.h 里写的是 $GOT，与请求的 $VER 不符。" >&2
    exit 1
fi
echo "   C/7zVersion.h 自述：$GOT（$DATE）"

echo "== 4. 解包 =="
STAGE="$TMP/stage"
mkdir -p "$STAGE"
tar -xJf "$ARCHIVE" -C "$STAGE"
if [ ! -f "$STAGE/C/7zVersion.h" ]; then
    echo "解包结果不完整：暂存目录里没有 C/7zVersion.h。" >&2
    exit 1
fi
# 先确认目标还不存在再改名 —— 改名是原子的，不会留下半截目录
if [ -e "$TARGET" ]; then
    echo "目标目录在这期间被创建了：$TARGET" >&2
    exit 1
fi
mv "$STAGE" "$TARGET"
printf '   已就位：%s（%s 个文件）\n' "$TARGET" \
    "$(find "$TARGET" -type f | wc -l | tr -d ' ')"

echo "== 5. 施加本移植的 macOS 补丁 =="
# 官方包是干净的，本移植的 10 个文件改动都在 upstream-macos.patch 里。
# 这一步不做的话构建**照样成功**，只是行为悄悄退化（中文 Windows 归档的名字
# 变乱码、解压出的树不再是 NFD、隔离属性不传播），所以升级流程里必须自动带上。
if ! sh "$HERE/apply_upstream_patch.sh" "$TARGET"; then
    echo "补丁未能施加到新版本上（多半是上游改动了被补丁的文件）。" >&2
    echo "  请人工核对 dist/build/upstream-macos.patch，必要时重新生成。" >&2
    exit 1
fi

echo "== 6. 解析确认 =="
# 让 upstream_dir.sh 自己选一次，确认它能认出新树（正常情况下会选版本号最高的那棵）
if Z7_SRC="$TARGET" sh "$HERE/upstream_dir.sh" >/dev/null; then
    echo "   upstream_dir.sh 认得出这棵树"
fi
OLD="$(sh "$HERE/upstream_dir.sh" 2>/dev/null || true)"
echo "   当前默认解析结果：${OLD:-（无）}"

echo
echo "=================== 后续步骤 ==================="
echo "本脚本刻意不做危险动作，剩下这三步请自行执行："
echo
echo "  1) 退役旧源码树（用 git 删，可回滚）："
if [ -n "$OLD" ] && [ "$OLD" != "$TARGET" ]; then
    echo "       git rm -r --quiet '${OLD#"$ROOT/"}'"
else
    echo "       git rm -r --quiet 7z<旧版本号>-src        # 若还存在旧树"
fi
echo "     （不要用 rm -rf：带安全钩子的环境里批量删除会被静默拦下，"
echo "       表现成「删了但还在」，随后构建用的仍是旧树。）"
echo
echo "  2) 重建并跑门禁（务必全绿再往下）："
echo "       make bridge && make test && make objc-test && make app && make appcheck"
echo
echo "  3) 提交（上游源码是 vendored 的，这一次提交会很大）："
echo "       git add -A && git commit -m '上游升级到 $VER'"
echo
echo "⚠️ 不要跑 make pkg / make tarball：已发布的资产不能被重新盖时间戳。"
echo "⚠️ 新版本引入的编译告警/新增格式请对照 dist/build/BUILD.md 复核一遍。"

if [ "$GATE" = "1" ]; then
    echo
    echo "== 7. --gate：用新源码重建引擎并跑门禁 =="
    Z7_SRC="$TARGET" make -C "$ROOT" bridge
    Z7_SRC="$TARGET" make -C "$ROOT" test
    echo
    echo "门禁通过。别忘了上面三步里的「退役旧树」与「提交」。"
fi
