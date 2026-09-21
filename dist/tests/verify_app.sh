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
QLTOOL="$APP/Contents/PlugIns/7ZipQuickLook.appex/Contents/Resources/7zz"

# ---------------------------------------------------------------------------
head1 "1. 包结构"

[ -x "$BIN" ]     && ok "主可执行文件存在且可执行"        || bad "缺少 $BIN"
[ -f "$DYLIB" ]   && ok "内嵌引擎动态库存在"              || bad "缺少 $DYLIB"
[ -f "$APP/Contents/Info.plist" ] && ok "Info.plist 存在" || bad "缺少 Info.plist"
[ -f "$APP/Contents/Resources/THIRD_PARTY.md" ] \
    && ok "第三方归属文档已随包分发" || bad "缺少 THIRD_PARTY.md（应用内许可入口会回退到内置摘要）"

# 应用级 7zz 已于 2026-09-22 审计中移除：SevenZipFindTool() 的候选列表只解析到
# appex 自身，且沙盒只允许执行带 com.apple.security.inherit 的助手（宿主应用那份
# 无任何 entitlement），运行时实测其日志亦落在 appex 内。因此这里反过来守卫：
# 真正的助手在 appex 里且带权限，应用包里不该再有第二份 6 MB 副本。
[ -x "$QLTOOL" ] \
    && ok "Quick Look 扩展自带 7zz 助手" || bad "缺少 appex 内的 7zz（Quick Look 预览会失效）"
if [ -f "$QLTOOL" ]; then
    codesign -d --entitlements - "$QLTOOL" 2>/dev/null | grep -q "com.apple.security.inherit" \
        && ok "助手带 inherit 权限（沙盒可执行）" || bad "助手缺少 inherit 权限，沙盒下无法启动"
fi
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

for SLICE in arm64 x86_64; do
    if lipo -archs "$BIN" | grep -qw "$SLICE"; then
        ok "主程序包含 $SLICE 切片"
    else
        bad "主程序缺少 $SLICE 切片"
    fi
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
