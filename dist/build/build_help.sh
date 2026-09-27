#!/bin/sh
#
# build_help.sh — 给应用包内的 Apple Help Book 生成搜索索引。
#
# 为什么需要这一步：帮助菜单里那个系统搜索框搜的就是这份索引。没有它，帮助书
# 仍然可以正常翻阅（HPDBookAccessPath 指向的页面照打不误），但搜索框查不到任何
# 东西——即「帮助在，但搜不到」，是一个很安静的缺陷，所以这一步失败即构建失败。
#
# 索引格式是私有二进制，只能由系统自带的 hiutil 生成（/usr/bin/hiutil，macOS
# 恒有，不需要任何第三方依赖）。
#
# 索引**不放进仓库**：它是构建产物，HTML 内容一改就过期。让构建时重新生成，
# 就不会出现「仓库里的索引描述的是上一版页面」这种无人察觉的偏差。
#
# 用法：sh build_help.sh <目标 .app 路径>

set -e

APP="$1"
HERE="$(cd "$(dirname "$0")" && pwd)"
DIST="$(cd "$HERE/.." && pwd)"

if [ -z "$APP" ] || [ ! -d "$APP" ]; then
    echo "usage: sh build_help.sh <path-to-7-Zip.app>" >&2
    exit 1
fi

if ! command -v hiutil >/dev/null 2>&1; then
    echo "找不到 hiutil，无法生成帮助索引（帮助书仍可用，但搜不到内容）" >&2
    exit 1
fi

MARK="$HERE/.build"
mkdir -p "$MARK"

for lang in en zh-Hans; do
    BOOK="$APP/Contents/Resources/$lang.lproj/7-Zip.help"
    RES="$BOOK/Contents/Resources"
    [ -d "$RES" ] || { echo "缺少帮助书资源目录：$RES" >&2; exit 1; }

    # 先删掉旧索引再生成。否则 hiutil 会把上一版索引文件也当成一个待索引的页面
    # 扫进去（它是二进制，虽无害但是噪音），而且增量覆盖的语义也不清楚。
    rm -f "$RES/7-Zip.cshelpindex"

    # 生成到 .build 下再复制进去，避免 hiutil 扫描的目录里同时存在输出文件。
    OUT="$MARK/helpindex-$lang.cshelpindex"
    hiutil -I corespotlight -C -a -f "$OUT" "$RES"
    cp -f "$OUT" "$RES/7-Zip.cshelpindex"
    echo "   帮助索引：$lang ($(wc -c < "$RES/7-Zip.cshelpindex" | tr -d ' ') 字节)"
done
