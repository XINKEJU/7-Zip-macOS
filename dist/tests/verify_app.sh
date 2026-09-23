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

# App 不应再派生 7zz；NSTask 类若仍被引用说明还有子进程调用路径
if nm -u "$BIN" 2>/dev/null | grep -q '_OBJC_CLASS_$_NSTask'; then
    bad "主程序仍引用 NSTask（存在子进程调用路径）"
else
    ok "主程序未引用 NSTask（归档操作全在进程内）"
fi

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
        N7=$(for c in $CHILDREN; do ps -p "$c" -o comm= 2>/dev/null; done | grep -c '7zz' || true)
        [ "${N7:-0}" -eq 0 ] && ok "无 7zz 子进程（共 ${#CHILDREN} 个子进程，均非 7zz）" \
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
