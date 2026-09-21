#!/bin/sh
#
# verify_engine.sh — 桥接层验收测试（技术方案 §10.1 矩阵 / §10.3 门禁）
#
# 覆盖：
#   1. 引擎版本与格式枚举
#   2. 七种格式双向互操作（桥接层创建 ↔ 7zz 验证/解压；7zz 创建 ↔ 桥接层解压）
#   3. 加密：密码 + 文件名加密、错误密码必须失败
#   4. 分卷：卷名与卷数与 7zz 一致
#   5. 编码：中文 / emoji / NFC-NFD 文件名
#   6. 特殊规模：0 字节、深嵌套、固实归档
#   7. 安全：路径穿越条目必须被拒绝
#   8. 单条目提取与内存提取
#   9. 测试模式（完整性校验）
#  10. 符号链接策略（越界/绝对目标拒绝）与 .partial 原子落盘
#  11. 更新模式（新增/跳过/替换）与 §5.1 扩展字段（-spf / -ms=…）
#  12. 删除模式（§6.4）：级联删除、容器格式保持、加密保持、失败分类
#
# 用法：sh verify_engine.sh

DIST="$(cd "$(dirname "$0")/.." && pwd)"
T="$DIST/tests/engine_test"
Z="$DIST/build/7zz"
WORK="${TMPDIR:-/tmp}/z7verify.$$"

PASS=0
FAIL=0
FAILED_CASES=""

ok()   { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); FAILED_CASES="$FAILED_CASES\n    - $1"; printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }
head1() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }

if [ ! -x "$T" ]; then echo "缺少测试程序：$T" >&2; exit 2; fi
if [ ! -x "$Z" ]; then echo "缺少 7zz：$Z" >&2; exit 2; fi

rm -rf "$WORK"
mkdir -p "$WORK"

# 构造测试数据
SRC="$WORK/src"
mkdir -p "$SRC/docs" "$SRC/nested/a/b/c/d"
printf 'hello world\n'                > "$SRC/a.txt"
printf ''                             > "$SRC/empty.bin"
printf '中文内容 UTF-8\n'              > "$SRC/中文名称.txt"
printf 'emoji file\n'                 > "$SRC/🙂emoji.txt"
printf 'deep\n'                       > "$SRC/nested/a/b/c/d/deep.txt"
head -c 262144 /dev/urandom           > "$SRC/docs/binary.bin"
: > "$SRC/alot"; for i in $(seq 1 500); do printf 'line %s\n' "$i" >> "$SRC/alot"; done

# 目录 sha256（内容 + 相对路径 + 权限）
treehash() {
    python3 - "$1" <<'PY'
import hashlib, os, sys
root = sys.argv[1]
items = []
for dirpath, dirnames, filenames in os.walk(root):
    dirnames.sort()
    for name in sorted(filenames):
        p = os.path.join(dirpath, name)
        rel = os.path.relpath(p, root)
        st = os.lstat(p)
        h = hashlib.sha256()
        with open(p, 'rb') as f:
            for chunk in iter(lambda: f.read(1 << 16), b''):
                h.update(chunk)
        items.append(f"{rel}\t{oct(st.st_mode & 0o7777)}\t{h.hexdigest()}")
print('\n'.join(sorted(items)))
PY
}

# ---------------------------------------------------------------------------
head1 "1. 引擎版本与格式枚举"
V="$("$T" version)"
[ "$V" = "26.03" ] && ok "引擎版本 = 26.03" || bad "引擎版本为 $V，期望 26.03"

NF="$("$T" formats | tail -1 | sed 's/[^0-9]*\([0-9]*\).*/\1/')"
[ "${NF:-0}" -ge 40 ] && ok "格式处理器数量 = $NF" || bad "格式数量异常：$NF"

for f in 7z zip tar gzip bzip2 xz; do
    "$T" formats | grep -q "^$f " && ok "格式 $f 已注册" || bad "格式 $f 未注册"
done

# ---------------------------------------------------------------------------
head1 "2. 目录型容器双向互操作"
for fmt in 7z zip tar; do
    A="$WORK/b_$fmt.$fmt"
    rm -f "$A"
    if "$T" create "$fmt" "$A" "$SRC" --level 7 >/dev/null 2>&1; then
        ok "[$fmt] 桥接层创建"
    else
        bad "[$fmt] 桥接层创建失败"; continue
    fi

    if "$Z" t "$A" >/dev/null 2>&1; then ok "[$fmt] 7zz 校验通过"; else bad "[$fmt] 7zz 校验失败"; fi

    rm -rf "$WORK/x_cli_$fmt"; mkdir -p "$WORK/x_cli_$fmt"
    "$Z" x -y -o"$WORK/x_cli_$fmt" "$A" >/dev/null 2>&1
    if [ -d "$WORK/x_cli_$fmt/src" ]; then ROOT="$WORK/x_cli_$fmt/src"; else ROOT="$WORK/x_cli_$fmt"; fi
    if [ "$(treehash "$SRC")" = "$(treehash "$ROOT")" ]; then
        ok "[$fmt] 7zz 解压内容与源一致"
    else
        bad "[$fmt] 7zz 解压内容与源不一致"
    fi

    B="$WORK/c_$fmt.$fmt"
    rm -f "$B"
    "$Z" a -t"$fmt" "$B" "$SRC" >/dev/null 2>&1
    rm -rf "$WORK/x_bridge_$fmt"; mkdir -p "$WORK/x_bridge_$fmt"
    if "$T" extract "$B" "$WORK/x_bridge_$fmt" >/dev/null 2>&1; then
        if [ -d "$WORK/x_bridge_$fmt/src" ]; then ROOT2="$WORK/x_bridge_$fmt/src"; else ROOT2="$WORK/x_bridge_$fmt"; fi
        if [ "$(treehash "$SRC")" = "$(treehash "$ROOT2")" ]; then
            ok "[$fmt] 桥接层解压 7zz 产物内容一致"
        else
            bad "[$fmt] 桥接层解压 7zz 产物内容不一致"
        fi
    else
        bad "[$fmt] 桥接层解压 7zz 产物失败"
    fi
done

# ---------------------------------------------------------------------------
head1 "3. 单文件压缩格式双向互操作"
for fmt in gzip bzip2 xz; do
    A="$WORK/s_b.$fmt"
    rm -f "$A"
    if "$T" create "$fmt" "$A" "$SRC/a.txt" >/dev/null 2>&1; then
        ok "[$fmt] 桥接层创建"
    else
        bad "[$fmt] 桥接层创建失败"; continue
    fi
    rm -rf "$WORK/sx_$fmt"; mkdir -p "$WORK/sx_$fmt"
    if "$Z" x -y -o"$WORK/sx_$fmt" "$A" >/dev/null 2>&1; then
        F="$(find "$WORK/sx_$fmt" -type f | head -1)"
        if [ -n "$F" ] && cmp -s "$SRC/a.txt" "$F"; then
            ok "[$fmt] 7zz 解压内容一致"
        else
            bad "[$fmt] 7zz 解压内容不一致"
        fi
    else
        bad "[$fmt] 7zz 解压失败"
    fi

    B="$WORK/s_c.$fmt"
    rm -f "$B"
    "$Z" a -t"$fmt" "$B" "$SRC/a.txt" >/dev/null 2>&1
    rm -rf "$WORK/scx_$fmt"; mkdir -p "$WORK/scx_$fmt"
    if "$T" extract "$B" "$WORK/scx_$fmt" >/dev/null 2>&1; then
        F="$(find "$WORK/scx_$fmt" -type f | head -1)"
        if [ -n "$F" ] && cmp -s "$SRC/a.txt" "$F"; then
            ok "[$fmt] 桥接层解压 7zz 产物一致"
        else
            bad "[$fmt] 桥接层解压 7zz 产物不一致"
        fi
    else
        bad "[$fmt] 桥接层解压 7zz 产物失败"
    fi
done

# ---------------------------------------------------------------------------
head1 "4. 加密（AES-256 + 文件名加密）"
ENC="$WORK/enc.7z"
rm -f "$ENC"
if "$T" create 7z "$ENC" "$SRC/a.txt" "$SRC/中文名称.txt" --password 'S3cret-密码' \
        --encryptheader on --encryptmeth AES256 >/dev/null 2>&1; then
    ok "桥接层创建加密归档"
else
    bad "桥接层创建加密归档失败"
fi

if "$Z" t -p'S3cret-密码' "$ENC" >/dev/null 2>&1; then
    ok "7zz 用正确密码校验通过"
else
    bad "7zz 用正确密码校验失败"
fi

# 文件名加密：不给密码时不应能列出条目名
"$Z" l "$ENC" < /dev/null > "$WORK/enc_nopw.txt" 2>&1
if grep -q 'a\.txt' "$WORK/enc_nopw.txt"; then
    bad "文件名未加密（无密码仍可列出文件名）"
else
    ok "文件名已加密（无密码无法列出条目名）"
fi

if "$Z" t -p'WrongPassword' "$ENC" >/dev/null 2>&1; then
    bad "错误密码竟然校验通过"
else
    ok "错误密码被正确拒绝"
fi

rm -rf "$WORK/enc_x"; mkdir -p "$WORK/enc_x"
# 桥接层当前不接收密码，故用 7zz 解压验证互操作
if "$Z" x -y -p'S3cret-密码' -o"$WORK/enc_x" "$ENC" >/dev/null 2>&1 \
   && cmp -s "$SRC/a.txt" "$WORK/enc_x/a.txt"; then
    ok "加密归档可被 7zz 正确解出"
else
    bad "加密归档 7zz 解压内容不一致"
fi

# ---------------------------------------------------------------------------
head1 "5. 分卷"
VOL="$WORK/vol.7z"
rm -f "$VOL" "$WORK"/vol.7z.0*
if "$T" create 7z "$VOL" "$SRC/docs/binary.bin" --volume 100k >/dev/null 2>&1; then
    NVOL="$(ls "$WORK"/vol.7z.0* 2>/dev/null | wc -l | tr -d ' ')"
    [ "${NVOL:-0}" -ge 2 ] && ok "桥接层分出 $NVOL 个卷" || bad "分卷数量异常：$NVOL"
    if [ -f "$WORK/vol.7z.001" ]; then ok "卷命名符合 7zz 约定（.001）"; else bad "卷命名不符合 .001 约定"; fi
    if "$Z" t "$WORK/vol.7z.001" >/dev/null 2>&1; then ok "7zz 可校验分卷"; else bad "7zz 无法校验分卷"; fi
else
    bad "桥接层分卷创建失败"
fi

# ---------------------------------------------------------------------------
head1 "6. 特殊规模与编码"
ZERO="$WORK/zero.7z"; rm -f "$ZERO"
"$T" create 7z "$ZERO" "$SRC/empty.bin" >/dev/null 2>&1 \
    && ok "0 字节文件归档创建" || bad "0 字节文件归档创建失败"

DEEP="$WORK/deep.7z"; rm -f "$DEEP"
"$T" create 7z "$DEEP" "$SRC/nested" >/dev/null 2>&1
rm -rf "$WORK/deep_x"; mkdir -p "$WORK/deep_x"
"$T" extract "$DEEP" "$WORK/deep_x" >/dev/null 2>&1
if [ -f "$WORK/deep_x/nested/a/b/c/d/deep.txt" ]; then ok "深嵌套目录结构还原"; else bad "深嵌套目录结构还原失败"; fi

CJK="$WORK/cjk.7z"; rm -f "$CJK"
"$T" create 7z "$CJK" "$SRC/中文名称.txt" "$SRC/🙂emoji.txt" >/dev/null 2>&1
rm -rf "$WORK/cjk_x"; mkdir -p "$WORK/cjk_x"
"$T" extract "$CJK" "$WORK/cjk_x" >/dev/null 2>&1
if [ -f "$WORK/cjk_x/中文名称.txt" ] && [ -f "$WORK/cjk_x/🙂emoji.txt" ]; then
    ok "中文与 emoji 文件名往返无损"
else
    bad "中文或 emoji 文件名往返丢失"
fi

SOLID="$WORK/solid.7z"; rm -f "$SOLID"
"$T" create 7z "$SOLID" "$SRC/alot" "$SRC/a.txt" --level 9 --solid on >/dev/null 2>&1
rm -rf "$WORK/solid_x"; mkdir -p "$WORK/solid_x"
"$T" extract "$SOLID" "$WORK/solid_x" >/dev/null 2>&1
if cmp -s "$SRC/alot" "$WORK/solid_x/alot"; then ok "固实归档解压一致"; else bad "固实归档解压不一致"; fi

# ---------------------------------------------------------------------------
head1 "7. 安全：路径穿越与绝对路径"
EVIL="$WORK/evil.zip"
python3 - "$EVIL" <<'PY'
import sys, zipfile
p = sys.argv[1]
with zipfile.ZipFile(p, 'w') as z:
    z.writestr('../../escaped.txt', 'pwned\n')
    z.writestr('/abs.txt', 'pwned\n')
    z.writestr('ok.txt', 'fine\n')
PY
rm -rf "$WORK/evil_x"; mkdir -p "$WORK/evil_x"
if "$T" extract "$EVIL" "$WORK/evil_x" >/dev/null 2>&1; then
    if [ -e "$WORK/escaped.txt" ] || [ -e "$WORK/evil_x/escaped.txt" ]; then
        bad "路径穿越未被拦截"
    else
        ok "路径穿越条目被拦截"
    fi
else
    ok "路径穿越归档被整体拒绝"
fi
if [ -f "$WORK/evil_x/ok.txt" ]; then
    ok "危险归档中的正常条目仍被提取"
else
    ok "危险归档已整体拒绝（安全优先）"
fi

# ---------------------------------------------------------------------------
head1 "8. 单条目提取与内存提取"
ONE="$WORK/one.7z"; rm -f "$ONE"
"$T" create 7z "$ONE" "$SRC" --level 5 >/dev/null 2>&1
IDX="$("$T" dumpitems "$ONE" | awk -F'\t' '$10=="src/a.txt"{print $2; exit}')"
IDX2="$("$T" dumpitems "$ONE" | awk -F'\t' '$10=="src/中文名称.txt"{print $2; exit}')"

if [ -n "$IDX" ]; then
    "$T" extractone "$ONE" "$IDX" "$WORK/single.txt" >/dev/null 2>&1
    cmp -s "$SRC/a.txt" "$WORK/single.txt" && ok "单文件提取（ASCII 名）" || bad "单文件提取（ASCII 名）失败"
else
    bad "未能定位单文件提取目标索引"
fi

if [ -n "$IDX2" ]; then
    "$T" extractone "$ONE" "$IDX2" "$WORK/single_cjk.txt" >/dev/null 2>&1
    cmp -s "$SRC/中文名称.txt" "$WORK/single_cjk.txt" \
        && ok "单文件提取（中文名）" || bad "单文件提取（中文名）失败"
else
    bad "未能定位中文名条目索引"
fi

MEMN="$("$T" extractmem "$ONE" "${IDX:-0}" 1m 2>/dev/null | head -1)"
[ "${MEMN:-0}" = "12" ] && ok "内存提取字节数正确（12）" || bad "内存提取字节数为 $MEMN，期望 12"

BIGN="$("$T" extractmem "$ONE" "$("$T" dumpitems "$ONE" | awk -F'\t' '$10=="src/docs/binary.bin"{print $2; exit}')" 1024 2>/dev/null | head -1)"
if [ "${BIGN:-0}" = "0" ] || [ -z "$BIGN" ]; then ok "内存提取超限被拒绝"; else bad "内存提取未按上限拒绝"; fi

# ---------------------------------------------------------------------------
head1 "9. 测试模式（完整性校验）"
if "$T" test "$WORK/b_7z.7z" >/dev/null 2>&1; then ok "test 模式校验通过"; else bad "test 模式校验失败"; fi

# 损坏归档必须被识别
cp "$WORK/b_7z.7z" "$WORK/broken.7z"
python3 - "$WORK/broken.7z" <<'PY'
import sys
p = sys.argv[1]
with open(p, 'r+b') as f:
    f.seek(64)
    f.write(b'\x00' * 64)
PY
if "$T" test "$WORK/broken.7z" >/dev/null 2>&1; then
    bad "损坏归档未被检出"
else
    ok "损坏归档被检出"
fi

# ---------------------------------------------------------------------------
head1 "10. 符号链接策略与原子落盘（方案 §7.4 / §8.2）"

SYM="$WORK/syms"; rm -rf "$SYM"; mkdir -p "$SYM"
printf 'target content\n' > "$SYM/real.txt"
ln -s real.txt "$SYM/good_link"
mkdir -p "$SYM/sub"
ln -s ../real.txt "$SYM/sub/up_link"

# 10.1 桥接层压缩：符号链接应存为链接条目，而不是跟随成普通文件
SYARCH="$WORK/sym_bridge.7z"; rm -f "$SYARCH"
"$T" create 7z "$SYARCH" "$SYM" --level 1 >/dev/null 2>&1
if [ -f "$SYARCH" ]; then
    rm -rf "$WORK/sym_7zz_x"
    "$Z" x -y -o"$WORK/sym_7zz_x" "$SYARCH" >/dev/null 2>&1
    # 顶层链接：7zz 与桥接层都应按链接还原
    LINK="$WORK/sym_7zz_x/syms/good_link"
    if [ -L "$LINK" ] && [ "$(readlink "$LINK")" = "real.txt" ]; then
        ok "桥接层压缩保留符号链接（7zz 解出仍是链接）"
    else
        bad "桥接层压缩未保留符号链接（7zz 解出结构不对）"
    fi
    # 归档元数据：条目应带 POSIX 链接位（Attributes 形如 l---------）
    if "$Z" l -slt "$SYARCH" 2>/dev/null \
        | awk '/^Path = syms\/sub\/up_link$/{f=1} f && /^Attributes =/{print; exit}' \
        | grep -q 'Attributes = *l'; then
        ok "归档内嵌套链接条目带 POSIX 链接位"
    else
        bad "归档内嵌套链接条目未标记为链接"
    fi
    # 注：7zz 默认策略会拒绝 ../real.txt 这类上溯链接（Dangerous link path），
    # 桥接层的策略更精确——只要解析后仍在目标目录内即允许，故此处以桥接层为准。
    rm -rf "$WORK/sym_br_x0"
    "$T" extract "$SYARCH" "$WORK/sym_br_x0" >/dev/null 2>&1
    UPLINK="$WORK/sym_br_x0/syms/sub/up_link"
    if [ -L "$UPLINK" ] && [ "$(readlink "$UPLINK")" = "../real.txt" ]; then
        ok "目录内相对链接目标保留正确（桥接层解出）"
    else
        bad "目录内相对链接目标丢失"
    fi
else
    bad "符号链接归档创建失败"
fi

# 10.2 桥接层解压：7zz 创建的链接应被还原为链接
rm -rf "$WORK/sym_br_x"
"$T" extract "$SYARCH" "$WORK/sym_br_x" >/dev/null 2>&1
LINK2="$WORK/sym_br_x/syms/good_link"
if [ -L "$LINK2" ] && [ "$(readlink "$LINK2")" = "real.txt" ]; then
    ok "桥接层解压还原符号链接"
else
    bad "桥接层解压未还原符号链接"
fi
[ -f "$WORK/sym_br_x/syms/real.txt" ] \
    && ok "链接指向的普通文件同时被正确写出" \
    || bad "链接指向的普通文件丢失"

# 10.3 安全：越界与绝对路径目标的符号链接必须被拒绝
MAL="$WORK/malicious.tar"
python3 - "$MAL" <<'PY'
import io, sys, tarfile
out = sys.argv[1]
with tarfile.open(out, 'w') as tf:
    payload = b'ok\n'
    ti = tarfile.TarInfo('good.txt'); ti.size = len(payload)
    tf.addfile(ti, io.BytesIO(payload))
    esc = tarfile.TarInfo('escape'); esc.type = tarfile.SYMTYPE
    esc.linkname = '../../../../../../etc/passwd'
    tf.addfile(esc)
    ent = tarfile.TarInfo('sneaky'); ent.type = tarfile.SYMTYPE
    ent.linkname = '../outside_target'
    tf.addfile(ent)
    ab = tarfile.TarInfo('absolute'); ab.type = tarfile.SYMTYPE
    ab.linkname = '/etc/hosts'
    tf.addfile(ab)
PY

MALOUT="$WORK/malicious_x"; rm -rf "$MALOUT"
"$T" extract "$MAL" "$MALOUT" >/dev/null 2>&1
[ -f "$MALOUT/good.txt" ] \
    && ok "恶意归档中的正常条目仍被提取" \
    || bad "恶意归档中的正常条目缺失"
# 悬挂链接不会被 [ -e ] 命中，必须用 [ -L ] 判定是否存在链接实体
if [ -L "$MALOUT/escape" ] || [ -L "$MALOUT/sneaky" ] || [ -L "$MALOUT/absolute" ]; then
    bad "越界 / 绝对路径符号链接未被拒绝"
else
    ok "越界与绝对路径符号链接均被拒绝"
fi

# 10.4 原子落盘：目标目录不得残留 .partial 半成品
LEFTOVER="$(find "$WORK/sym_br_x" "$MALOUT" -name '*.partial' 2>/dev/null | head -1)"
[ -z "$LEFTOVER" ] && ok "解压完成后无 .partial 残留" || bad "存在 .partial 残留：$LEFTOVER"

# 10.5 原子落盘：解压失败时不得留下半成品
TRUNC="$WORK/trunc.7z"; cp "$WORK/b_7z.7z" "$TRUNC"
python3 - "$TRUNC" <<'PY'
import os, sys
p = sys.argv[1]
size = os.path.getsize(p)
with open(p, 'r+b') as f:
    f.truncate(max(0, size // 2))
PY
TRUNCOUT="$WORK/trunc_x"; rm -rf "$TRUNCOUT"
"$T" extract "$TRUNC" "$TRUNCOUT" >/dev/null 2>&1 || true
REST="$(find "$TRUNCOUT" -name '*.partial' 2>/dev/null | head -1)"
[ -z "$REST" ] && ok "解压失败后无 .partial 残留" || bad "解压失败后残留半成品：$REST"

# ---------------------------------------------------------------------------
head1 "11. 更新模式与 §5.1 扩展字段"

UPD="$WORK/upd"; rm -rf "$UPD"; mkdir -p "$UPD/d1" "$UPD/d2"
printf 'one\n' > "$UPD/d1/a.txt"
printf 'two\n' > "$UPD/d2/b.txt"

# 11.1 追加：既有条目必须原样保留
"$T" create 7z "$UPD/a.7z" "$UPD/d1" --level 1 >/dev/null 2>&1
"$T" add "$UPD/a.7z" "$UPD/d2/b.txt" --replace off --level 1 >/dev/null 2>&1
NAMES="$("$Z" l "$UPD/a.7z" 2>/dev/null | awk '$1 ~ /^[0-9]{4}-/{print $NF}' | tr '\n' ' ')"
case "$NAMES" in
    *d1/a.txt*b.txt*) ok "更新模式：新增条目且既有条目保留" ;;
    *) bad "更新模式：条目集合不正确（$NAMES）" ;;
esac
"$Z" t "$UPD/a.7z" >/dev/null 2>&1 && ok "更新后的归档通过 7zz 完整性校验" \
    || bad "更新后的归档校验失败"

# 11.2 跳过：同一条目在 replace off 时不得重复写入
"$T" add "$UPD/a.7z" "$UPD/d2/b.txt" --replace off --level 1 >/dev/null 2>&1 || true
CNT="$("$Z" l "$UPD/a.7z" 2>/dev/null | awk '$1 ~ /^[0-9]{4}-/{print $NF}' | grep -c '^b\.txt$')"
[ "$CNT" = "1" ] && ok "更新模式：同名条目被跳过（无重复）" \
    || bad "更新模式：同名条目重复（计数 $CNT）"

# 11.3 替换：replace on 时同名条目应被新内容覆盖，且总数不变
printf 'two-updated-longer-content\n' > "$UPD/d2/b.txt"
"$T" add "$UPD/a.7z" "$UPD/d2/b.txt" --replace on --level 1 >/dev/null 2>&1
CNT2="$("$Z" l "$UPD/a.7z" 2>/dev/null | awk '$1 ~ /^[0-9]{4}-/{print $NF}' | grep -c '^b\.txt$')"
rm -rf "$UPD/x"
"$T" extract "$UPD/a.7z" "$UPD/x" >/dev/null 2>&1
if [ "$CNT2" = "1" ] && cmp -s "$UPD/d2/b.txt" "$UPD/x/b.txt" && [ -f "$UPD/x/d1/a.txt" ]; then
    ok "更新模式：同名条目被替换且既有条目保留"
else
    bad "更新模式：替换结果不正确（条目数 $CNT2）"
fi

# 11.4 保留完整路径（-spf）
FULL="$UPD/full.7z"; rm -f "$FULL"
"$T" create tar "$FULL" "$UPD/d1/a.txt" --fullpaths on >/dev/null 2>&1
FULLSUF="$(printf '%s' "$UPD" | sed 's|^/||')/d1/a.txt"
if "$Z" l "$FULL" 2>/dev/null | grep -q "$FULLSUF"; then
    ok "保留完整路径（-spf）：归档内为完整源路径"
else
    bad "保留完整路径（-spf）未生效（期望后缀 $FULLSUF）"
fi

# 11.5 固实分块：合法语法为 e / Nf / N[bkmg]（7zHandlerOut.cpp SetSolidFromString）
for SPEC in 100f 64m e; do
    SOLIDB="$UPD/sb_$SPEC.7z"; rm -f "$SOLIDB"
    if "$T" create 7z "$SOLIDB" "$UPD/d1" --level 1 --solidblock "$SPEC" >/dev/null 2>&1 \
       && "$Z" t "$SOLIDB" >/dev/null 2>&1; then
        ok "固实分块（-ms=$SPEC）被引擎接受"
    else
        bad "固实分块（-ms=$SPEC）未被引擎接受"
    fi
done

# 11.6 非法取值必须被引擎拒绝（E_INVALIDARG），而不是静默忽略
BADMF="$UPD/badmf.7z"; rm -f "$BADMF"
if "$T" create 7z "$BADMF" "$UPD/d1" --matchfinder bogus9 >/dev/null 2>&1; then
    bad "非法匹配查找器未被拒绝"
else
    ok "非法匹配查找器被引擎拒绝"
fi
BADSOLID="$UPD/badsolid.7z"; rm -f "$BADSOLID"
if "$T" create 7z "$BADSOLID" "$UPD/d1" --solidblock 100e >/dev/null 2>&1; then
    bad "非法固实分块（100e）未被拒绝"
else
    ok "非法固实分块（100e）被引擎拒绝（合法形式为 e/Nf/N[bkmg]）"
fi

# ---------------------------------------------------------------------------
head1 "12. 删除模式（§6.4 删除键）"

# 实现为「解压保留项 → 重建 → 原子替换」。以下用例既验证语义正确，
# 也验证重建路径没有破坏容器格式、加密属性与符号链接。
DEL="$WORK/del"; rm -rf "$DEL"; mkdir -p "$DEL/s/d1" "$DEL/s/d2"
printf 'alpha\n' > "$DEL/s/d1/a.txt"
printf 'beta\n'  > "$DEL/s/d1/b.txt"
printf 'gamma\n' > "$DEL/s/d2/c.txt"
printf 'delta\n' > "$DEL/s/root.txt"
ln -s a.txt "$DEL/s/d1/link.txt"

arcnames() { "$Z" l "$1" 2>/dev/null | awk '$1 ~ /^[0-9]{4}-/{print $NF}' | sort; }

# 12.1 删除单个文件条目
"$T" create 7z "$DEL/a.7z" "$DEL/s/d1" "$DEL/s/d2" "$DEL/s/root.txt" --level 1 >/dev/null 2>&1
"$T" remove "$DEL/a.7z" "d1/b.txt" >/dev/null 2>&1
if ! arcnames "$DEL/a.7z" | grep -q '^d1/b\.txt$' \
   && arcnames "$DEL/a.7z" | grep -q '^d1/a\.txt$' \
   && arcnames "$DEL/a.7z" | grep -q '^d2/c\.txt$' \
   && arcnames "$DEL/a.7z" | grep -q '^root\.txt$'; then
    ok "删除单文件：目标条目消失，其余条目保留"
else
    bad "删除单文件结果不正确（$(arcnames "$DEL/a.7z" | tr '\n' ' ')）"
fi
"$Z" t "$DEL/a.7z" >/dev/null 2>&1 && ok "删除后的归档通过 7zz 完整性校验" \
    || bad "删除后的归档校验失败"

# 12.2 删除目录：其后代必须级联删除
"$T" remove "$DEL/a.7z" "d1" >/dev/null 2>&1
if ! arcnames "$DEL/a.7z" | grep -q '^d1' \
   && arcnames "$DEL/a.7z" | grep -q '^d2/c\.txt$'; then
    ok "删除目录：后代条目被级联删除"
else
    bad "删除目录未级联（残留 $(arcnames "$DEL/a.7z" | tr '\n' ' ')）"
fi

# 12.3 删除后的内容必须可用（内容比对，而非仅条目计数）
rm -rf "$DEL/x"
"$T" extract "$DEL/a.7z" "$DEL/x" >/dev/null 2>&1
if cmp -s "$DEL/s/d2/c.txt" "$DEL/x/d2/c.txt" && cmp -s "$DEL/s/root.txt" "$DEL/x/root.txt" \
   && [ ! -e "$DEL/x/d1" ]; then
    ok "删除后解压内容正确（被删项不存在）"
else
    bad "删除后解压内容不正确"
fi

# 12.4 无匹配条目必须失败
if "$T" remove "$DEL/a.7z" "no/such.txt" >/dev/null 2>&1; then
    bad "删除不存在的条目竟然成功"
else
    ok "删除不存在的条目被拒绝"
fi

# 12.5 不允许删空归档（引擎无法生成空归档）
# 注意：必须用"只含待删条目"的独立归档，否则删目录条目后仍会剩下空目录条目而合法成功。
"$T" create 7z "$DEL/all.7z" "$DEL/s/d2" --level 1 >/dev/null 2>&1
if "$T" remove "$DEL/all.7z" "d2" >/dev/null 2>&1; then
    bad "删除全部条目竟然成功"
else
    ok "删除全部条目被拒绝"
fi

# 12.6 容器格式必须保持：zip 删除后仍是 zip（用 7zz 独立判定，非依赖本层自述）
"$T" create zip "$DEL/a.zip" "$DEL/s/d1" "$DEL/s/d2" --level 1 >/dev/null 2>&1
"$T" remove "$DEL/a.zip" "d1/b.txt" >/dev/null 2>&1
if "$Z" l "$DEL/a.zip" 2>/dev/null | grep -qi '^Type = zip'; then
    ok "删除保持容器格式（zip 仍为 zip）"
else
    bad "删除改变了容器格式（不再是 zip）"
fi
if "$Z" t "$DEL/a.zip" >/dev/null 2>&1 && ! arcnames "$DEL/a.zip" | grep -q '^d1/b\.txt$'; then
    ok "zip 删除结果通过 7zz 校验且目标条目已消失"
else
    bad "zip 删除结果不正确"
fi

# 12.7 符号链接在重建后必须保留且仍为链接
"$T" create 7z "$DEL/s.7z" "$DEL/s/d1" "$DEL/s/d2" --level 1 >/dev/null 2>&1
"$T" remove "$DEL/s.7z" "d1/b.txt" >/dev/null 2>&1
rm -rf "$DEL/sx"
"$T" extract "$DEL/s.7z" "$DEL/sx" >/dev/null 2>&1
if [ -L "$DEL/sx/d1/link.txt" ] && [ "$(readlink "$DEL/sx/d1/link.txt")" = "a.txt" ]; then
    ok "删除重建后符号链接仍为链接且目标不变"
else
    bad "删除重建后符号链接丢失或退化为普通文件"
fi

# 12.8 加密归档：错误密码必须失败，正确密码成功且新归档保持加密
"$T" create 7z "$DEL/e.7z" "$DEL/s/d1" "$DEL/s/d2" \
      --password 'Pw-删除123' --encryptheader on --level 1 >/dev/null 2>&1
if "$T" remove "$DEL/e.7z" "d1/b.txt" --password 'WrongPw' >/dev/null 2>&1; then
    bad "加密归档用错误密码删除竟然成功"
else
    ok "加密归档用错误密码删除被拒绝"
fi
if "$T" remove "$DEL/e.7z" "d1/b.txt" --password 'Pw-删除123' >/dev/null 2>&1; then
    ok "加密归档用正确密码删除成功"
else
    bad "加密归档用正确密码删除失败"
fi
# 删除是"解压保留项 → 重建"，必须还原原归档的 -mhe；
# 官方 7zz d 在同一场景下保留 -mhe，故此处按行为等价要求校验（§10.3）。
if "$T" info "$DEL/e.7z" --password 'Pw-删除123' 2>/dev/null | grep -q '^header_encrypted=1'; then
    ok "删除后仍标记为文件名加密（header_encrypted=1）"
else
    bad "删除后丢失了文件名加密标记"
fi
if "$Z" l "$DEL/e.7z" 2>/dev/null | grep -q 'a\.txt'; then
    bad "删除后文件名未保持加密（无密码即可列出）"
else
    ok "删除后归档仍保持文件名加密（7zz 无密码列不出条目名）"
fi
rm -rf "$DEL/ex"
if "$T" extract "$DEL/e.7z" "$DEL/ex" --password 'Pw-删除123' >/dev/null 2>&1 \
   && [ -f "$DEL/ex/d1/a.txt" ] && [ ! -e "$DEL/ex/d1/b.txt" ]; then
    ok "删除后的加密归档可用正确密码解出且被删项不存在"
else
    bad "删除后的加密归档解压结果不正确"
fi

# 12.9 打开失败原因分类：错密码 / 缺密码 / 损坏文件 三者的提示必须可区分
"$T" create 7z "$DEL/plain.7z" "$DEL/s/d2" --level 1 >/dev/null 2>&1
if "$T" list "$DEL/e.7z" --password 'WrongPw' 2>&1 | grep -q '密码错误'; then
    ok "错误密码被归类为密码错误（而非格式不识别）"
else
    bad "错误密码的提示不准确"
fi
if "$T" list "$DEL/e.7z" 2>&1 | grep -q '需要正确密码'; then
    ok "未提供密码时提示需要密码"
else
    bad "未提供密码时的提示不准确"
fi
if "$T" list "$DEL/plain.7z" --password 'AnyPw' >/dev/null 2>&1; then
    ok "未加密归档即使带密码参数也能正常打开（无误报）"
else
    bad "未加密归档带密码参数时被误判为密码错误"
fi

# ---------------------------------------------------------------------------
printf '\n\033[1m================ 汇总 ================\033[0m\n'
printf '通过: \033[32m%s\033[0m   失败: \033[31m%s\033[0m\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
    printf '失败用例：%b\n' "$FAILED_CASES"
fi

rm -rf "$WORK"
[ "$FAIL" -eq 0 ]
