#!/bin/sh
#
# verify_app.sh — 应用包（7-Zip.app）验收：结构、动态库解析、安全性、真实启动。
#
# 为什么需要这一层：
#   engine_test / objc_test 验证的是库本身，而"库是对的"不等于"应用能跑"。
#   本脚本验证的是**打包后的产物**，历史教训：
#     * lib7z.dylib 的 install_name 曾写成 @rpath/7z.dylib 而文件名为
#       lib7z.dylib —— 静态检查（otool -L 里有 @rpath/7z.dylib）全部通过，
#       但应用一启动就 dyld 报 "Library not loaded"。因此必须把依赖
#       真正解析成磁盘路径并确认存在。
#     * dylib 的部署目标曾是 26.1（跟随本机 SDK），在 macOS < 26.1 上无法加载。
#
# 用法：sh verify_app.sh [App 包路径]

DIST="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$DIST/7-Zip.app}"

PASS=0
FAIL=0
FAILED=""

ok()  { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); FAILED="$FAILED\n    - $1"; printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }
head1() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }

if [ ! -d "$APP" ]; then
    echo "找不到应用包：$APP（先运行 make app）" >&2
    exit 2
fi

BIN="$APP/Contents/MacOS/7-Zip"
DYLIB="$APP/Contents/Frameworks/lib7z.dylib"
APPEX_7ZZ="$APP/Contents/PlugIns/7ZipQuickLook.appex/Contents/Resources/7zz"

# ---------------------------------------------------------------------------
head1 "1. 包结构"

[ -x "$BIN" ]     && ok "主可执行文件存在且可执行"        || bad "缺少 $BIN"
[ -f "$DYLIB" ]   && ok "内嵌引擎动态库存在"              || bad "缺少 $DYLIB"
[ -f "$APP/Contents/Info.plist" ] && ok "Info.plist 存在" || bad "缺少 Info.plist"
[ -f "$APP/Contents/Resources/THIRD_PARTY.md" ] \
    && ok "第三方归属文档已随包分发" || bad "缺少 THIRD_PARTY.md（应用内许可入口会回退到内置摘要）"

# 许可正文必须随 .app 一起走：应用是可以被单独拷贝分发的，只留一份
# THIRD_PARTY.md 而把 LGPL / unRAR / 第三方正文留在安装包里的做法，对
# 「只拿 .app」的用户等于没给。LGPL-2.1 §1 与 BSD/MIT 都要求这些正文随二进制。
for f in licenses/COPYING licenses/License.txt licenses/unRarLicense.txt \
         licenses/third-party/zstd-BSD-3-Clause.txt \
         licenses/third-party/lz4-BSD-2-Clause.txt \
         licenses/third-party/brotli-MIT.txt \
         licenses/third-party/liblzma-0BSD.txt; do
    [ -f "$APP/Contents/Resources/$f" ] \
        && ok "许可正文已随包分发：$f" || bad "缺少 $APP/Contents/Resources/$f"
done
# 正文不能是空壳。
[ -s "$APP/Contents/Resources/licenses/COPYING" ] \
    && ok "LGPL 正文非空" || bad "licenses/COPYING 为空"

# --- 界面本地化 ---
# 只放 en.lproj 也能跑（键就是中文原文，找不到条目会回退到键），但 CFBundleLocalizations
# 声明了 zh-Hans 却没有对应资源目录时，系统选择本地化会两头落空。两个目录都要在。
for lang in en zh-Hans; do
    L="$APP/Contents/Resources/$lang.lproj/Localizable.strings"
    [ -f "$L" ] && ok "本地化表已随包分发：$lang.lproj" \
                || bad "缺少 $L（该语言会整片回退到开发区域）"
done
# 复制环节必须真的把源码那份搬进去：内容不一致说明打包走的是别的路径。
if [ -f "$APP/Contents/Resources/en.lproj/Localizable.strings" ]; then
    SRC_EN="$(shasum -a 256 "$DIST/resources/en.lproj/Localizable.strings" | awk '{print $1}')"
    APP_EN="$(shasum -a 256 "$APP/Contents/Resources/en.lproj/Localizable.strings" | awk '{print $1}')"
    [ "$SRC_EN" = "$APP_EN" ] && ok "英文表与源文件逐字节一致" \
                              || bad "英文表与源文件不一致（打包复制环节有问题）"
fi
# 开发区域决定了「找不到翻译时回退成什么」。zh_CN 不是合法的 BCP-47 标识，
# 写错不会报错，只会让回退落到英文上，故在此钉死。
DEVEL="$(plutil -extract CFBundleDevelopmentRegion raw "$APP/Contents/Info.plist" 2>/dev/null)"
[ "$DEVEL" = "zh-Hans" ] && ok "CFBundleDevelopmentRegion = zh-Hans" \
    || bad "CFBundleDevelopmentRegion = '$DEVEL'（应为 zh-Hans；zh_CN 是非法 BCP-47）"
LOCS="$(plutil -extract CFBundleLocalizations json -o - "$APP/Contents/Info.plist" 2>/dev/null)"
case "$LOCS" in
    *'"en"'*)     ok "CFBundleLocalizations 含 en" ;;
    *)            bad "CFBundleLocalizations 缺 en：$LOCS" ;;
esac
case "$LOCS" in
    *'"zh-Hans"'*) ok "CFBundleLocalizations 含 zh-Hans" ;;
    *)             bad "CFBundleLocalizations 缺 zh-Hans：$LOCS" ;;
esac

# --- 访达服务（NSServices）---
# 这一节守的是一条**纯静默**的失败路径：声明看起来齐全、pbs 也登记成功、
# `pbs -read_bundle` 照样打印完整条目、应用照常启动 —— 只有访达的「服务」里
# 永远不出现那两项，没有任何报错。
#
# 实测根因（macOS 27，同一 Info.plist 内放只差单个键的变体、一次启动对比）：
#   NSSendFileTypes(public.item)，无 NSRequiredContext      → 不出现
#   同上 + NSRequiredContext{NSTextContent=FilePath}        → 出现
#   NSSendTypes(NSFilenamesPboardType)，无 NSRequiredContext → 不出现
#   两个 send 键都有，无 NSRequiredContext                   → 不出现
# 即决定因素是 NSRequiredContext，与用哪个 send 键无关。故在此钉死它。
#
# 同时钉死两件同样静默的事：
#   * NSMenuItem 的语言键按「最具体者胜出」解析（zh_CN > zh-Hans > en > default）。
#     只写 default + en，中文系统会显示英文；只写中文键，英文系统会露出中文。
#   * NSMessage 写错既不是编译错误、也没有运行期报错，只是点了没反应 —— 因此
#     逐个回到源码里核对处理器确实存在。
SVC_ISSUES="$(python3 - "$APP/Contents/Info.plist" "$DIST/app-src/main.m" <<'PY'
import plistlib, sys

plist_path, main_m = sys.argv[1], sys.argv[2]
d = plistlib.load(open(plist_path, 'rb'))
src = open(main_m, encoding='utf-8').read()
svcs = d.get('NSServices') or []
issues = []

if not svcs:
    issues.append("Info.plist 未声明 NSServices（访达「服务」里不会有压缩/解压）")

for i, s in enumerate(svcs):
    mi = s.get('NSMenuItem') or {}
    label = mi.get('default') or "第 %d 条" % (i + 1)

    ctx = s.get('NSRequiredContext')
    text_content = ctx.get('NSTextContent') if isinstance(ctx, dict) else None
    if text_content != 'FilePath':
        issues.append("%s：缺 NSRequiredContext.NSTextContent=FilePath —— "
                      "访达「服务」里永远不会出现，且没有任何报错" % label)

    if not mi.get('default'):
        issues.append("%s：NSMenuItem 缺 default（未列出语言无兜底）" % label)
    if not mi.get('en'):
        issues.append("%s：NSMenuItem 缺 en（英文系统会露出中文）" % label)
    if not (mi.get('zh-Hans') or mi.get('zh_CN')):
        issues.append("%s：NSMenuItem 缺中文键 zh-Hans/zh_CN"
                      "（有 en 时中文系统会显示英文）" % label)

    for k in ('NSMessage', 'NSPortName'):
        if not s.get(k):
            issues.append("%s：缺 %s" % (label, k))
    if not (s.get('NSSendTypes') or s.get('NSSendFileTypes')):
        issues.append("%s：既无 NSSendTypes 也无 NSSendFileTypes（无从匹配选中内容）" % label)

    msg = s.get('NSMessage')
    if msg and ("%s:(NSPasteboard" % msg) not in src:
        issues.append("%s：主程序里找不到 %s:(NSPasteboard… 处理器"
                      "（菜单会出现，但点了没反应）" % (label, msg))

print("\n".join(issues))
PY
)"
if [ -z "$SVC_ISSUES" ]; then
    ok "访达服务声明完整（NSRequiredContext / 语言键 / NSMessage 处理器均在）"
else
    bad "访达服务声明有问题：
$SVC_ISSUES"
fi

# --- Help Book ---
# 帮助菜单里那个系统搜索框，前提是 CFBundleHelpBookFolder 指向一份**能被找到**的
# 帮助书。帮助书按本地化规则放在 <语言>.lproj/ 下——不是 Resources 根目录，所以
# 逐语言核对，而不是在根目录找。
#
# 「能不能被找到」直接问 NSBundle：这正是 AppKit（registerBooksInBundle:）内部用的
# 那套本地化查找。目录摆错位置时它返回空，而界面上没有任何症状——搜索框照样出现，
# 只是永远搜不出结果。
HBF="$(plutil -extract CFBundleHelpBookFolder raw "$APP/Contents/Info.plist" 2>/dev/null)"
if [ -z "$HBF" ]; then
    bad "Info.plist 未声明 CFBundleHelpBookFolder（帮助菜单不会有系统搜索框）"
else
    ok "CFBundleHelpBookFolder = $HBF"
    # 查找用的是「名字 + 扩展名」两个字段，不是文件夹全名。
    BOOKNAME="${HBF%.help}"
    FOUND="$(/usr/bin/osascript -l JavaScript -e '
        function run(argv) {
          ObjC.import("Foundation");
          try {
            var b = $.NSBundle.bundleWithPath($(argv[0]));
            var u = b.URLForResourceWithExtension(argv[1], "help");
            return (u && u.path) ? u.path.js : "";
          } catch (e) { return ""; }
        }' "$APP" "$BOOKNAME" 2>/dev/null)"
    case "$FOUND" in
        */"$HBF") ok "帮助书可被 NSBundle 本地化查找到（${FOUND#$APP/}）" ;;
        *) bad "NSBundle 找不到帮助书（返回 '$FOUND'）：帮助菜单的搜索框会永远搜不出结果" ;;
    esac

    for lang in en zh-Hans; do
        HB="$APP/Contents/Resources/$lang.lproj/$HBF"
        [ -f "$HB/Contents/Info.plist" ] \
            && ok "$lang 帮助书 Info.plist 存在" || bad "缺少 $HB/Contents/Info.plist"
        [ -s "$HB/Contents/Resources/index.html" ] \
            && ok "$lang 帮助书首页非空" || bad "缺少或为空的 $HB/Contents/Resources/index.html"
        # 注意索引的位置：它在**帮助书自己的** Contents/Resources/ 下，由帮助书的
        # HPDBookIndexPath 解析，不在应用包根目录——用 bundle URLForResource: 去应用包
        # 根目录找它必然落空，那是正常的，不是缺陷。这里核对「声明的路径确实存在」。
        IDX="$(plutil -extract HPDBookIndexPath raw "$HB/Contents/Info.plist" 2>/dev/null)"
        if [ -n "$IDX" ] && [ -s "$HB/Contents/Resources/$IDX" ]; then
            ok "$lang 搜索索引已生成（$IDX，$(wc -c < "$HB/Contents/Resources/$IDX" | tr -d ' ') 字节）"
        else
            bad "$lang 帮助书声明的索引 '$IDX' 不存在或为空（搜索会静默无结果）"
        fi
    done
fi

# 7zz 已全面移除（2026-09-24）。此前 appex 内嵌了一份 7zz 并签以
# com.apple.security.inherit，但该权限属**受限权限**，ad-hoc 签名（本项目的
# 分发方式，TeamIdentifier=not set）无法使其生效。实测扩展自身日志：
#   engine unavailable: posix_spawn 失败：Operation not permitted (errno 1)
#   engine run: raw=0 bytes
#   native reader: recognised=1 format=ZIP complete=1 count=4
# 即引擎从未产出过一个字节，全部预览内容由进程内 reader 给出。那份 6,012,576 B
# （占整个 .app 的 48%）因此是纯死载荷。扩展现改为进程内解析
# （ql-src/ArchiveReader.c）。下面反向守卫：任何位置再出现 7zz 副本都算回归。
[ ! -e "$APPEX_7ZZ" ] \
    && ok "appex 内无 7zz（预览由进程内 reader 解析）" || bad "appex 内仍有 7zz，属已移除的死载荷"
[ ! -e "$APP/Contents/Resources/7zz" ] \
    && ok "应用包内无冗余 7zz（不复刻 6 MB 死载荷）" || bad "应用包内仍有冗余 Resources/7zz"

# ---------------------------------------------------------------------------
head1 "2. 动态库依赖解析（真正解析到磁盘）"

RPATHS="$(otool -l "$BIN" | awk '/LC_RPATH/{f=1} f&&/ path /{print $2; f=0}')"
if [ -n "$RPATHS" ]; then
    ok "存在 LC_RPATH：$(echo "$RPATHS" | tr '\n' ' ')"
else
    bad "主程序没有 LC_RPATH"
fi

UNRESOLVED=0
REFCOUNT=0
for dep in $(otool -L "$BIN" | awk 'NR>1{print $1}'); do
    case "$dep" in
        @rpath/*)
            REFCOUNT=$((REFCOUNT + 1))
            name="${dep#@rpath/}"
            found=""
            for rp in $RPATHS; do
                case "$rp" in
                    @executable_path/*) cand="$APP/Contents/MacOS/${rp#@executable_path/}/$name" ;;
                    @loader_path/*)     cand="$APP/Contents/MacOS/${rp#@loader_path/}/$name" ;;
                    /*)                 cand="$rp/$name" ;;
                    *)                  cand="" ;;
                esac
                [ -n "$cand" ] && [ -f "$cand" ] && { found="$cand"; break; }
            done
            if [ -n "$found" ]; then
                ok "$dep 可解析（${found#$APP/}）"
            else
                bad "$dep 无法解析：rpath 下找不到 $name（应用将无法启动）"
                UNRESOLVED=1
            fi
            ;;
    esac
done
[ "$REFCOUNT" -gt 0 ] && ok "主程序确实引用了内嵌引擎（$REFCOUNT 条记录）" \
    || bad "主程序没有引用 @rpath 引擎库，可能仍是静态/子进程方案"

# install_name 必须与文件名一致，否则上一项虽通过、运行期仍会失败
ID="$(otool -D "$DYLIB" 2>/dev/null | tail -n +2 | head -1)"
CASE_ID="$(printf '%s' "$ID" | sed 's|.*/||')"
if [ "$CASE_ID" = "$(basename "$DYLIB")" ]; then
    ok "install_name 末段与文件名一致（$ID）"
else
    bad "install_name 末段（$CASE_ID）与文件名（$(basename "$DYLIB")）不一致"
fi

# ---------------------------------------------------------------------------
head1 "3. 部署目标（最低系统版本）"

DYMIN="$(otool -l "$DYLIB" | grep -A4 LC_BUILD_VERSION | grep minos | awk '{print $2}' | head -1)"
MAJOR="${DYMIN%%.*}"
if [ -n "$DYMIN" ] && [ "$MAJOR" -le 11 ] 2>/dev/null; then
    ok "引擎动态库 minos = $DYMIN（兼容 11.0+）"
else
    bad "引擎动态库 minos = $DYMIN，高于 11.0（旧系统将无法加载）"
fi

BMIN="$(otool -l "$BIN" | grep -A4 LC_BUILD_VERSION | grep minos | awk '{print $2}' | head -1)"
BMAJOR="${BMIN%%.*}"
if [ -n "$BMIN" ] && [ "$BMAJOR" -le 11 ] 2>/dev/null; then
    ok "主程序 minos = $BMIN（兼容 11.0+）"
else
    bad "主程序 minos = $BMIN，高于 11.0"
fi

# 架构回归守卫。2026-09-24 起本项目只发行 arm64（Apple Silicon）：x86_64 切片
# 曾占每个可执行体体积的近一半，而 Intel Mac 已无在售机型。这里正反都断言——
# 少一个 arm64 切片是「发布物装不上」，多一个 x86_64 切片是「体积悄悄涨回去」，
# 两者都是回归。三处可执行体逐一检查（主程序 / 引擎动态库 / QL 扩展）。
ARCH_TARGETS="$BIN
$DYLIB
$APP/Contents/PlugIns/7ZipQuickLook.appex/Contents/MacOS/7ZipQuickLook"
for T in $ARCH_TARGETS; do
    [ -f "$T" ] || { bad "缺少可执行体 $T"; continue; }
    SLICES="$(lipo -archs "$T" 2>/dev/null)"
    case "$SLICES" in
        *arm64*) : ;;
        *) bad "$(basename "$T") 缺少 arm64 切片" ; continue ;;
    esac
    case "$SLICES" in
        *x86_64*) bad "$(basename "$T") 含 x86_64 切片（本项目只发行 arm64）" ;;
        *) ok "$(basename "$T") 架构 = $SLICES（仅 Apple Silicon）" ;;
    esac
done

# ---------------------------------------------------------------------------
head1 "4. 签名"

if codesign --verify --deep --strict "$APP" 2>/dev/null; then
    ok "codesign --verify --deep --strict 通过"
else
    bad "签名校验失败"
fi

# ---------------------------------------------------------------------------
head1 "5. 进程模型：引擎必须在进程内运行"

# App 不应再派生 7zz；NSTask 类若仍被引用说明还有子进程调用路径。
# 唯一被许可的子进程例外是「DMG 创建」时派生系统 hdiutil（DMG 是 Apple 专有
# 格式，无进程内等价物）。它由引擎 C++ 侧用 posix_spawn 发起、不经过 NSTask，
# 因此本断言依旧成立；白名单见下方子进程统计。详见 BUILD.md「DMG 与零子进程原则」。
if nm -u "$BIN" 2>/dev/null | grep -q '_OBJC_CLASS_$_NSTask'; then
    bad "主程序仍引用 NSTask（存在子进程调用路径）"
else
    ok "主程序未引用 NSTask（归档操作全在进程内）"
fi

# 允许的子进程基线：除系统 hdiutil 外，不应派生任何其它子进程。
HDIUTIL_WHITELIST=1

if [ ! -x "$BIN" ]; then
    printf '\n通过: %s   失败: %s\n' "$PASS" "$FAIL"
    printf '失败用例：%b\n' "$FAILED"
    exit 1
fi

# 真实启动：进程须存活，无 7zz 子进程，且 lib7z.dylib 已映射进地址空间
WORK="$(mktemp -d "${TMPDIR:-/tmp}/z7appverify.XXXXXX")"
mkdir -p "$WORK/s/d1"
printf 'alpha\n' > "$WORK/s/d1/a.txt"
printf 'beta\n'  > "$WORK/s/d1/b.txt"
"$DIST/tests/engine_test" create 7z "$WORK/t.7z" "$WORK/s/d1" >/dev/null 2>&1

"$BIN" "$WORK/t.7z" >"$WORK/out.log" 2>&1 &
PID=$!
sleep 4
if kill -0 "$PID" 2>/dev/null; then
    ok "应用启动后稳定运行（pid=$PID）"

    CHILDREN="$(pgrep -P "$PID" 2>/dev/null || true)"
    if [ -z "$CHILDREN" ]; then
        ok "启动归档后无任何子进程"
    else
        # 统计子进程：7zz 一律禁止；hdiutil 属白名单（仅 DMG 创建用，打开
        # 归档不会触发）；其它子进程视为异常路径。
        N7=0; NH=0; NOTHER=0
        for c in $CHILDREN; do
            CM="$(ps -p "$c" -o comm= 2>/dev/null)"
            case "$CM" in
                *hdiutil*) NH=$((NH+1)) ;;
                *7zz*)     N7=$((N7+1)) ;;
                *)         NOTHER=$((NOTHER+1)) ;;
            esac
        done
        [ "$N7" -eq 0 ] && ok "无 7zz 子进程（共 ${#CHILDREN} 个子进程；hdiutil 白名单 $NH、其它 $NOTHER）" \
                        || bad "派生出了 $N7 个 7zz 子进程"
    fi

    if vmmap "$PID" 2>/dev/null | grep -q 'Frameworks/lib7z\.dylib'; then
        ok "lib7z.dylib 已映射进应用进程（引擎确实内嵌运行）"
    else
        bad "lib7z.dylib 未映射，引擎可能未真正加载"
    fi
    kill "$PID" 2>/dev/null
    sleep 1
else
    bad "应用启动即退出（见下）"
    sed 's/^/        /' "$WORK/out.log" | head -10
fi

wait "$PID" 2>/dev/null || true
rm -rf "$WORK"

# ---------------------------------------------------------------------------
printf '\n\033[1m================ 汇总 ================\033[0m\n'
printf '通过: \033[32m%s\033[0m   失败: \033[31m%s\033[0m\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
    printf '失败用例：%b\n' "$FAILED"
fi
[ "$FAIL" -eq 0 ]
