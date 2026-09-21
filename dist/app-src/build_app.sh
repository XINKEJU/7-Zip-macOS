#!/bin/sh
#
# build_app.sh — assembles 7-Zip.app from the sources in this directory.
#
# Produces a universal (arm64 + x86_64) application bundle:
#   * the front end links the in-process engine bridge
#     (lib7zbridgeobjc.a + lib7zbridge.a) and loads lib7z.dylib from
#     Contents/Frameworks, so archive work runs inside the app process
#     (no 7zz child process for the app's own operations);
#   * no 7zz is shipped in the application bundle itself. The Quick Look
#     extension is self-contained: ql-src/build_ql.sh places its own copy at
#     Contents/PlugIns/7ZipQuickLook.appex/Contents/Resources/7zz and signs it
#     with the helper entitlements (7zz-helper.entitlements) that the sandbox
#     requires. See ql-src/SevenZipPreviewProvider.m — SevenZipFindTool() only
#     ever resolves inside that appex, never in the host application, so an
#     extra copy here would be 6 MB of dead payload (audit 2026-09-22).
#
# Usage:  sh build_app.sh <path-to-7zip.icns> <output-dir>

set -e

ICNS="$1"
OUTDIR="$2"
HERE="$(cd "$(dirname "$0")" && pwd)"
DIST="$(cd "$HERE/.." && pwd)"
LIB="$DIST/lib"
ENG_DIR="$DIST/engine"

if [ -z "$ICNS" ] || [ -z "$OUTDIR" ]; then
    echo "usage: sh build_app.sh <7zip.icns> <output-dir>" >&2
    exit 1
fi

for f in "$LIB/lib7z.dylib" "$LIB/lib7zbridge.a" "$LIB/lib7zbridgeobjc.a"; do
    if [ ! -f "$f" ]; then
        echo "缺少 $f，请先运行 sh dist/engine/build_dylib.sh 与 sh dist/engine/build_engine.sh" >&2
        exit 2
    fi
done

APP="$OUTDIR/7-Zip.app"
BUILD="$HERE/.build"

echo "== 1. 校验 Info.plist =="
plutil -lint "$HERE/Info.plist"

echo "== 2. 编译两个架构（部署目标 11.0）=="
mkdir -p "$BUILD"
export MACOSX_DEPLOYMENT_TARGET=11.0
for arch in arm64 x86_64; do
    clang -fobjc-arc -fmodules -Wall -O2 \
          -arch "$arch" -mmacosx-version-min=11.0 \
          -I"$ENG_DIR" -I"$LIB" \
          -framework AppKit -framework Foundation -framework QuickLookUI -framework CoreFoundation \
          -o "$BUILD/app-$arch" "$HERE/main.m" \
          "$LIB/lib7zbridgeobjc.a" "$LIB/lib7zbridge.a" \
          -L"$LIB" -l7z -lc++ \
          -Wl,-rpath,@executable_path/../Frameworks
    printf "   %-8s %s bytes\n" "$arch" "$(stat -f%z "$BUILD/app-$arch")"
done

echo "== 3. 合并通用二进制 =="
lipo -create "$BUILD/app-arm64" "$BUILD/app-x86_64" -output "$BUILD/app-universal"
lipo -archs "$BUILD/app-universal" | sed 's/^/   架构: /'

echo "== 4. 组装 .app 包 =="
# 不整体删除旧包：批量 rm 会被安全钩子拦截并使脚本中止（表现为"改了脚本但产物
# 没变"）。改为就地覆盖——本脚本写入的路径集合是固定的，逐文件 cp 即为正确结果；
# 若历史布局留下过陈旧文件，末尾的 codesign --verify --deep --strict 会因为
# 该文件未被签名而失败，因此这一步本身就是"无残留"的守卫。
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp -f "$BUILD/app-universal"     "$APP/Contents/MacOS/7-Zip"
cp -f "$HERE/Info.plist"         "$APP/Contents/Info.plist"
cp -f "$ICNS"                    "$APP/Contents/Resources/7zip.icns"
cp -f "$LIB/lib7z.dylib"         "$APP/Contents/Frameworks/lib7z.dylib"
# 应用包不再携带 7zz（审计 2026-09-22：宿主应用那份从不被执行，纯占 6.01 MB）。
# 这里的残留清理不能省：上面那段"就地覆盖"策略下，历史上由本脚本放进来的
# Resources/7zz 会留在包里，而且第 7 步的 codesign --deep 会把它一并签进封存，
# 于是末尾的签名校验根本不会报警——陈旧 6 MB 会被静默保留。因此显式删这一个
# 已知路径（单个 rm -f，不涉及批量通配）。
rm -f "$APP/Contents/Resources/7zz"
# 第三方归属与许可（§2.3 / P5）：应用内「致谢与许可…」读取该文件。
# 与 package.sh / make_installer.sh 保持同一门禁：文件缺失即视为许可完整性
# 缺陷而中止，不发行缺少归属声明的应用包（About 面板的运行时回退仅作为
# 加载失败时的最后防线保留）。
THIRD="$DIST/../THIRD_PARTY.md"
if [ -f "$THIRD" ]; then
    cp -f "$THIRD" "$APP/Contents/Resources/THIRD_PARTY.md"
else
    echo "缺少 $THIRD，应用包将不满足许可完整性要求" >&2
    exit 1
fi
chmod 755 "$APP/Contents/MacOS/7-Zip" \
          "$APP/Contents/Frameworks/lib7z.dylib"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "== 5. 嵌入引擎校验 =="
# 应用级 7zz 已移除；需要校验的是 Quick Look 扩展内那份（由 build_ql.sh 在
# 第 8 步放置并签名），此处只断言"应用包里不该再有 7zz"。
if [ -e "$APP/Contents/Resources/7zz" ]; then
    echo "   应用包内仍有 Resources/7zz，残留未清！" >&2; exit 1
fi
echo "   应用包内无冗余 7zz（Quick Look 扩展自带宽）"
DSRC="$(shasum -a 256 "$LIB/lib7z.dylib" | awk '{print $1}')"
DEMBED="$(shasum -a 256 "$APP/Contents/Frameworks/lib7z.dylib" | awk '{print $1}')"
[ "$DSRC" = "$DEMBED" ] && echo "   lib7z.dylib 与源产物一致" || { echo "   lib7z.dylib 不一致！" >&2; exit 1; }

echo "== 6. 动态库依赖校验 =="
# 仅检查"引用了 @rpath/xxx"是不够的：install_name 与文件名不一致时这里会通过、
# 但应用启动时 dyld 会直接报 "Library not loaded"。必须把每个 @rpath/@executable_path
# 依赖实际解析成磁盘路径并确认存在。
BIN="$APP/Contents/MacOS/7-Zip"
RPATHS="$(otool -l "$BIN" | awk '/LC_RPATH/{f=1} f&&/ path /{print $2; f=0}')"
[ -n "$RPATHS" ] && echo "   rpath: $(echo "$RPATHS" | tr '\n' ' ')" \
    || { echo "   主程序没有 LC_RPATH！" >&2; exit 1; }

UNRESOLVED=0
for dep in $(otool -L "$BIN" | awk 'NR>1{print $1}'); do
    case "$dep" in
        @rpath/*)
            name="${dep#@rpath/}"
            found=""
            for rp in $RPATHS; do
                case "$rp" in
                    @executable_path/*)
                        cand="$APP/Contents/MacOS/${rp#@executable_path/}/$name" ;;
                    @loader_path/*)
                        cand="$APP/Contents/MacOS/${rp#@loader_path/}/$name" ;;
                    /*) cand="$rp/$name" ;;
                    *)  cand="" ;;
                esac
                [ -n "$cand" ] && [ -f "$cand" ] && { found="$cand"; break; }
            done
            if [ -n "$found" ]; then
                echo "   $dep -> ${found#$APP/}"
            else
                echo "   无法解析依赖：$dep（在 rpath 下找不到 $name）" >&2
                UNRESOLVED=1
            fi
            ;;
        @executable_path/*|@loader_path/*)
            rel="${dep#@*/}"
            cand="$APP/Contents/MacOS/$rel"
            [ -f "$cand" ] && echo "   $dep -> ${cand#$APP/}" \
                || { echo "   无法解析依赖：$dep" >&2; UNRESOLVED=1; }
            ;;
    esac
done
[ "$UNRESOLVED" -eq 0 ] || { echo "   存在未解析的动态库依赖，应用将无法启动！" >&2; exit 1; }

DYMIN="$(otool -l "$APP/Contents/Frameworks/lib7z.dylib" | grep -A4 LC_BUILD_VERSION | grep minos | awk '{print $2}' | head -1)"
case "$DYMIN" in
    11.*|1[0-9].*|2[0-5].*) echo "   引擎动态库部署目标 = $DYMIN（兼容 11.0+）" ;;
    *) echo "   引擎动态库部署目标 $DYMIN 高于 11.0，会导致旧系统无法加载！" >&2; exit 1 ;;
esac

# ---------------------------------------------------------------------------
# 扩展属性必须先清除，且必须在签名之前。
#
# pkgbuild 的载荷是一个 tar 流，tar 无法在 ustar 头里表示扩展属性，于是把它
# 编码成 AppleDouble 侧车文件（同目录下的 "._<名字>"）。而 macOS 会给它认为
# 来源不可信／由其他进程写入的文件自动打上 com.apple.provenance，一次
# `cp` 就会把它带进应用包——实测安装包中因此多出 55 个 "._*" 垃圾条目。
#
# 顺序不能颠倒：代码签名会把这些属性纳入封存，签名之后再清除等同于破坏签名。
echo "== 7. ad-hoc 签名 =="
xattr -cr "$APP" 2>/dev/null || true
codesign --force --deep --sign - --timestamp=none \
         --identifier org.7-zip.macos.app "$APP" 2>&1 | sed 's/^/   /'
codesign --verify --deep --strict "$APP" && echo "   签名校验通过"

echo "== 8. 构建 Quick Look 预览扩展 =="
QLBUILD="$OUTDIR/ql-src/build_ql.sh"
if [ -x "$QLBUILD" ]; then
    APP_BUNDLE="$APP" sh "$QLBUILD" 2>&1 | sed 's/^/   /'
else
    echo "   未找到 $QLBUILD，跳过"
fi

echo "== 9. 注册到 LaunchServices =="
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if [ -x "$LSREG" ]; then
    "$LSREG" -f "$APP" && echo "   已注册"
else
    echo "   未找到 lsregister，跳过"
fi
if [ -d "$APP/Contents/PlugIns/7ZipQuickLook.appex" ]; then
    pluginkit -a "$APP/Contents/PlugIns/7ZipQuickLook.appex" \
        && echo "   Quick Look 扩展已注册" || true
fi

echo
echo "== 结果 =="
du -sh "$APP" | sed 's/^/   /'
find "$APP" -type f -o -type l | sed "s|$APP|   7-Zip.app|"
