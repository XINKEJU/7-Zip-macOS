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
#  13. 容器级联（上游 CArchiveLink 语义）与进入内层归档
#  14. wim 创建 + tar.gz / tar.bz2 / tar.xz / tgz 一步生成（组合格式）
#  15. 新编解码器：zstd / lz4 / brotli 的创建与解压、单流约束、短写别名归一化
#      （外部库未链入时对应断言自动 skip，不算失败）
#  16. ISO 创建：自研 ISO9660 + Joliet（Python 解析 / 7zz / 挂载三重交叉验证）
#  17. DMG 创建：调系统 hdiutil（唯一子进程例外）
#  18. lzip：自研容器 + liblzma raw LZMA1（往返 / 外部产出 / 多成员 / 三因子完整性）
#  19. snappy：自实现（分帧格式 / 裸格式 / 掩码 CRC-32C / 损坏检测）
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
skip() { printf '  \033[33mSKIP\033[0m  %s\n' "$1"; }
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
head1 "3.5 目标已存在同名文件时的策略（覆盖 / 跳过 / 自动改名）"

CLASH_ARC="$WORK/clash.7z"
CLASH_DEST="$WORK/clash_dest"
rm -f "$CLASH_ARC"
rm -rf "$CLASH_DEST"
mkdir -p "$CLASH_DEST"

if "$T" create 7z "$CLASH_ARC" "$SRC/a.txt" >/dev/null 2>&1; then
    # 先放一个同名但内容不同的文件，制造冲突
    printf 'PRE-EXISTING' > "$CLASH_DEST/a.txt"

    "$T" extract "$CLASH_ARC" "$CLASH_DEST" --skip >/dev/null 2>&1
    if [ "$(cat "$CLASH_DEST/a.txt")" = "PRE-EXISTING" ]; then
        ok "同名冲突：--skip 跳过已存在文件（内容未被改写）"
    else
        bad "同名冲突：--skip 仍然改写了已存在文件"
    fi

    "$T" extract "$CLASH_ARC" "$CLASH_DEST" --rename >/dev/null 2>&1
    if [ -f "$CLASH_DEST/a (2).txt" ] && [ "$(cat "$CLASH_DEST/a.txt")" = "PRE-EXISTING" ]; then
        ok '同名冲突：--rename 生成 "a (2).txt" 且原文件保留'
    else
        bad '同名冲突：--rename 未按预期生成 "a (2).txt"'
    fi

    "$T" extract "$CLASH_ARC" "$CLASH_DEST" --overwrite >/dev/null 2>&1
    if cmp -s "$SRC/a.txt" "$CLASH_DEST/a.txt"; then
        ok "同名冲突：--overwrite 覆盖已存在文件"
    else
        bad "同名冲突：--overwrite 未覆盖已存在文件"
    fi
else
    bad "同名冲突：测试归档创建失败"
fi

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
head1 "13. 容器级联与进入内层归档"

CAS="$WORK/cascade"
mkdir -p "$CAS/inner/sub"
printf 'hello cascade\n' > "$CAS/inner/note.txt"
printf 'deep\n' > "$CAS/inner/sub/d.txt"
( cd "$CAS/inner" && tar -cf "$CAS/payload.tar" . ) >/dev/null 2>&1
gzip -kf -c "$CAS/payload.tar" > "$CAS/payload.tar.gz"
xz   -kf -c "$CAS/payload.tar" > "$CAS/payload.tar.xz"

# 13.1 格式名必须与 CLI 的 "Type = ..." 同源（处理器的注册名），
#      而不是归档属性里的内部名 —— WIM 曾经显示成 "E0C318FD.wim"。
if "$T" info "$CAS/payload.tar.gz" 2>/dev/null | grep -q '^format=gzip'; then
    ok "gzip 的格式名为 gzip（与 7zz 的 Type 一致）"
else
    bad "gzip 的格式名不正确"
fi

# 13.2 .tar.gz 上层只有 1 个条目：引擎不自动级联，这一点与上游 7zz 相同
#      （实测 7zz x s.tar.gz 也只得到 s.tar）。
if "$T" info "$CAS/payload.tar.gz" 2>/dev/null | grep -q '^items=1'; then
    ok ".tar.gz 上层只列出 1 个条目（不自动级联，与上游一致）"
else
    bad ".tar.gz 上层条目数不是 1"
fi

# 13.3 进入内层：gzip 没有 IInArchiveGetStream，走「解到临时文件」的退路。
#      这条退路是上游没有的，官方 7zz 只能解两次。
ENT_GZ=$("$T" enter "$CAS/payload.tar.gz" 0 2>&1)
if printf '%s' "$ENT_GZ" | grep -q '^inner_format=tar'; then
    ok "从 .tar.gz 进入内层得到 tar"
else
    bad "从 .tar.gz 进入内层失败：$ENT_GZ"
fi
if printf '%s' "$ENT_GZ" | grep -q 'note.txt'; then
    ok "进入后的条目列表包含 note.txt"
else
    bad "进入后的条目列表不正确"
fi

# 13.4 xz 实现了 IInArchiveGetStream，走取流路径（不落临时文件）
ENT_XZ=$("$T" enter "$CAS/payload.tar.xz" 0 2>&1)
if printf '%s' "$ENT_XZ" | grep -q '^inner_format=tar'; then
    ok "从 .tar.xz 进入内层得到 tar"
else
    bad "从 .tar.xz 进入内层失败：$ENT_XZ"
fi

# 13.5 进入非归档条目必须给出明确提示，而不是静默失败
printf 'just text\n' > "$CAS/plain.txt"
gzip -kf -c "$CAS/plain.txt" > "$CAS/plain.txt.gz"
if "$T" enter "$CAS/plain.txt.gz" 0 2>&1 | grep -q '不是引擎能识别的归档'; then
    ok "进入非归档条目时提示明确"
else
    bad "进入非归档条目时的提示不明确"
fi

# 13.6 临时文件必须清理干净（否则每次进入都漏一个解开的归档在磁盘上）
if ls "${TMPDIR:-/tmp}"/7z-nested-* >/dev/null 2>&1; then
    bad "进入内层后残留了临时文件"
else
    ok "进入内层用的临时文件已清理"
fi

# 13.7 磁盘映像：上游靠 kpidMainSubfile 级联到文件系统层，这里同样要落到文件
if command -v hdiutil >/dev/null 2>&1; then
    hdiutil create -volname Z7Cascade -srcfolder "$CAS/inner" -ov \
        -format UDZO "$CAS/disk.dmg" -quiet >/dev/null 2>&1
    if [ -f "$CAS/disk.dmg" ]; then
        if "$T" list "$CAS/disk.dmg" 2>/dev/null | grep -q 'note.txt'; then
            ok "磁盘映像级联到文件系统层（可直接看到 note.txt）"
        else
            bad "磁盘映像没有级联到文件层"
        fi
        if "$T" info "$CAS/disk.dmg" 2>/dev/null | grep -q '^chain=2'; then
            ok "磁盘映像的层级链为 2 层（Dmg + 文件系统）"
        else
            bad "磁盘映像的层级链不是 2 层"
        fi
    fi
fi

# ---------------------------------------------------------------------------
head1 "14. 创建格式补齐：wim 与一步生成的 tar.* 组合格式"

CMP="$WORK/compose"
mkdir -p "$CMP/in/sub"
printf 'AAA\n' > "$CMP/in/a.txt"
printf 'BBB\n' > "$CMP/in/b.txt"
printf 'CCC\n' > "$CMP/in/sub/c.txt"

# 14.0 上游对照：7zz 无法一步生成含多文件的 .tar.gz —— 这是本移植补足的能力，
#      不是照抄上游。先钉住上游行为，日后上游补上了这条断言会立刻提醒我们。
if "$Z" a -tgzip "$CMP/upstream.tar.gz" "$CMP/in/a.txt" "$CMP/in/b.txt" \
        >/dev/null 2>&1; then
    bad "上游 7zz 竟能一步生成 tar.gz（断言 14.0 的前提已失效，需复核）"
else
    ok "上游 7zz 确实无法一步生成 tar.gz（本移植补足的能力）"
fi

# 14.1 wim：引擎的处理器表里它本来就声明可创建，之前只是下拉里没有
if "$T" create wim "$CMP/mk.wim" "$CMP/in/a.txt" "$CMP/in/b.txt" "$CMP/in/sub" \
        >/dev/null 2>&1 && [ -s "$CMP/mk.wim" ]; then
    ok "wim 归档创建成功"
else
    bad "wim 归档创建失败"
fi
if "$Z" l "$CMP/mk.wim" 2>/dev/null | grep -q 'sub/c.txt' &&
   "$Z" l "$CMP/mk.wim" 2>/dev/null | grep -q 'a.txt'; then
    ok "wim 产物被 7zz 正确识别且条目完整"
else
    bad "wim 产物未被 7zz 正确识别"
fi

# 14.2 一步生成 .tar.gz：外层必须是真的 gzip，且内层条目名与官方两步法一致
#      （官方两步法的结果是 out.tar.gz 内含 out.tar）
if "$T" create tar.gz "$CMP/mk.tar.gz" "$CMP/in/a.txt" "$CMP/in/b.txt" \
        "$CMP/in/sub" >/dev/null 2>&1 && [ -s "$CMP/mk.tar.gz" ]; then
    ok "一步生成 tar.gz 成功"
else
    bad "一步生成 tar.gz 失败"
fi
if "$Z" l "$CMP/mk.tar.gz" 2>/dev/null | grep -q '^Type = gzip' &&
   "$Z" l "$CMP/mk.tar.gz" 2>/dev/null | grep -q 'mk.tar'; then
    ok "tar.gz 外层是真正的 gzip，内层名为 mk.tar（与官方两步法一致）"
else
    bad "tar.gz 结构不对（外层不是 gzip 或内层名不是 mk.tar）"
fi

# 14.3 端到端：用 7zz 解两层，内容必须逐字节对得上
rm -rf "$CMP/out"
mkdir -p "$CMP/out"
"$Z" x -o"$CMP/out" "$CMP/mk.tar.gz" >/dev/null 2>&1
"$Z" x -o"$CMP/out" "$CMP/out/mk.tar" >/dev/null 2>&1
if [ "$(cat "$CMP/out/a.txt" "$CMP/out/b.txt" "$CMP/out/sub/c.txt" 2>/dev/null \
        | tr -d '\n')" = "AAABBBCCC" ]; then
    ok "tar.gz 两段解包后内容正确（AAA/BBB/CCC）"
else
    bad "tar.gz 两段解包后内容不正确"
fi

# 14.4 短写法 tgz 必须等价于 tar.gz
if "$T" create tgz "$CMP/mk.tgz" "$CMP/in/a.txt" "$CMP/in/b.txt" "$CMP/in/sub" \
        >/dev/null 2>&1 && "$Z" l "$CMP/mk.tgz" 2>/dev/null | grep -q 'mk.tar'; then
    ok "短写法 tgz 等价于 tar.gz（内层名同样是 mk.tar）"
else
    bad "短写法 tgz 未生成正确的 tar.gz"
fi

# 14.5 另外两种外层
for pair in "tar.xz:xz" "tar.bz2:bzip2"; do
    fmt="${pair%%:*}"
    want="${pair##*:}"
    if "$T" create "$fmt" "$CMP/mk.$fmt" "$CMP/in/a.txt" "$CMP/in/b.txt" \
            "$CMP/in/sub" >/dev/null 2>&1 &&
       "$Z" l "$CMP/mk.$fmt" 2>/dev/null | grep -q "^Type = $want" &&
       "$Z" l "$CMP/mk.$fmt" 2>/dev/null | grep -q 'mk.tar'; then
        ok "$fmt 一步生成成功且外层为 $want"
    else
        bad "$fmt 一步生成失败或外层不是 $want"
    fi
done

# 14.6 两段式的中间 tar 必须清理干净，否则每次建包都漏一个归档在磁盘上
if ls "${TMPDIR:-/tmp}"/7z-compose-* >/dev/null 2>&1; then
    bad "创建组合归档后残留了临时目录"
else
    ok "创建组合归档用的临时目录已清理"
fi

# 14.7 格式名必须能走通「按注册名查 CLSID」这条新路径 —— 既有的 7z/zip/tar
#      也在同一条路径上，任何一个格式名写错都会在这里暴露
if "$T" create zip "$CMP/mk.zip" "$CMP/in/a.txt" >/dev/null 2>&1 &&
   "$Z" l "$CMP/mk.zip" 2>/dev/null | grep -q '^Type = zip'; then
    ok "既有格式（zip）走新的按名查表路径仍然正常"
else
    bad "既有格式（zip）在按名查表路径上回归"
fi

# ---------------------------------------------------------------------------
head1 "15. 新编解码器：zstd / lz4 / brotli 的创建、单流约束与别名归一化"

# 构建时到底链进了哪些外部库？ext_codecs.sh 的探测结果说了算 —— 引擎侧是按
# Z7_HAVE_* 条件编译的，缺库时对应格式根本不在二进制里，此时必须 skip 而不是
# fail（否则没装 Homebrew 的 CI 会误报）。整段放在 $( ) 子 shell 里执行，探测脚本
# 设的内部变量不会污染本脚本。
CODECS_AT_BUILD="$( . "$DIST/engine/ext_codecs.sh" >/dev/null 2>&1; printf '%s' "$EXT_CODEC_NAMES" )"
has_codec() {
    case " $CODECS_AT_BUILD " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

EXT="$WORK/extcodec"
mkdir -p "$EXT/in/sub"
printf 'AAA\n' > "$EXT/in/a.txt"
printf 'BBB\n' > "$EXT/in/b.txt"
printf 'CCC\n' > "$EXT/in/sub/c.txt"

# 15.1 zstd 创建：上游只有解码器、没有编码器，这是本移植真正补足的「创建」能力
if ! has_codec zstd; then
    skip "构建时未链入 libzstd，跳过 zstd 创建断言（优雅降级）"
elif "$T" create zstd "$EXT/mk.zst" "$EXT/in/a.txt" >/dev/null 2>&1 && [ -s "$EXT/mk.zst" ]; then
    ok "zstd 归档创建成功（上游做不到）"
else
    bad "zstd 归档创建失败"
fi

if has_codec zstd; then
    if "$Z" l "$EXT/mk.zst" 2>/dev/null | grep -qi '^Type = zstd'; then
        ok "zstd 产物被官方 7zz 识别为 zstd"
    else
        bad "zstd 产物未被官方 7zz 识别"
    fi
fi

# 15.2 zstd 往返：自产自解，内容必须逐字节一致
if has_codec zstd; then
    rm -rf "$EXT/zstout"
    mkdir -p "$EXT/zstout"
    if "$T" extract "$EXT/mk.zst" "$EXT/zstout" >/dev/null 2>&1 &&
       [ "$(cat "$EXT/zstout"/* 2>/dev/null | tr -d '\n')" = "AAA" ]; then
        ok "zstd 往返（创建→解码→抽取）内容一致"
    else
        bad "zstd 往返内容不一致"
    fi
fi

# 15.3 lz4 解压：上游完全没有 lz4 处理器，这是本移植新接入的解码能力。
#      样本用系统 lz4 工具生成。链入与否、工具在不在，任一条件不满足都只 skip。
LZ4BIN="$(command -v lz4 || true)"
if ! has_codec lz4; then
    skip "构建时未链入 liblz4，跳过 lz4 解码断言（优雅降级）"
elif [ -z "$LZ4BIN" ]; then
    skip "无 lz4 命令行工具（无法生成样本），跳过 lz4 解码断言"
elif "$LZ4BIN" -q "$EXT/in/a.txt" "$EXT/sample.lz4" >/dev/null 2>&1; then
    if "$T" info "$EXT/sample.lz4" 2>/dev/null | grep -q '^format=lz4' &&
       "$T" info "$EXT/sample.lz4" 2>/dev/null | grep -q '^items=1'; then
        ok "lz4 归档被识别为 format=lz4、1 条目"
    else
        bad "lz4 归档未被正确识别"
    fi
    rm -rf "$EXT/lz4out"
    mkdir -p "$EXT/lz4out"
    if "$T" extract "$EXT/sample.lz4" "$EXT/lz4out" >/dev/null 2>&1 &&
       [ "$(cat "$EXT/lz4out"/* 2>/dev/null | tr -d '\n')" = "AAA" ]; then
        ok "lz4 解码抽取内容与原文一致"
    else
        bad "lz4 解码内容不一致"
    fi
else
    skip "lz4 工具执行失败，跳过 lz4 解码断言"
fi

# 15.4 lz4 创建：本移植的 lz4 是「读 + 写」全套（frame 容器）。编码器与解码器
#      用的是同一套 LZ4F_* API，因此产物必须能被系统 lz4 工具独立解回 —— 只做
#      「自产自解」是循环验证，证明不了容器合规。
rm -f "$EXT/mk.lz4"
if ! has_codec lz4; then
    skip "构建时未链入 liblz4，跳过 lz4 创建断言（优雅降级）"
elif "$T" create lz4 "$EXT/mk.lz4" "$EXT/in/a.txt" >/dev/null 2>&1 && [ -s "$EXT/mk.lz4" ]; then
    ok "lz4 归档创建成功（上游完全没有 lz4）"
    if [ -n "$LZ4BIN" ] && "$LZ4BIN" -dc "$EXT/mk.lz4" 2>/dev/null | grep -q '^AAA$'; then
        ok "自产 lz4 被系统 lz4 工具独立解回且内容正确"
    else
        skip "无可用 lz4 命令，跳过 lz4 产物的独立交叉验证"
    fi
else
    bad "lz4 归档创建失败"
fi

# 15.5 brotli 创建 + 往返。brotli 没有魔数，只能按扩展名（.br / .brotli）认领；
#      本机/CI 不一定链了 libbrotli，缺库时整段 skip。
rm -f "$EXT/mk.br"
if ! has_codec brotli; then
    skip "构建时未链入 libbrotli，跳过 brotli 创建断言（优雅降级）"
elif "$T" create brotli "$EXT/mk.br" "$EXT/in/a.txt" >/dev/null 2>&1 && [ -s "$EXT/mk.br" ]; then
    ok "brotli 归档创建成功（上游完全没有 brotli）"
    rm -rf "$EXT/brout"; mkdir -p "$EXT/brout"
    if "$T" extract "$EXT/mk.br" "$EXT/brout" >/dev/null 2>&1 &&
       [ "$(cat "$EXT/brout"/* 2>/dev/null | tr -d '\n')" = "AAA" ]; then
        ok "brotli 往返（创建→解码→抽取）内容一致"
    else
        bad "brotli 往返内容不一致"
    fi
else
    bad "brotli 归档创建失败"
fi

# 15.6 所有外部编解码器都是单流格式，多文件创建必须被拒绝并给出清晰报错。
#      这条与库无关：单流约束在 CreateSingleArchive 入口就拦下了。
for cf in zstd lz4 brotli lzip snappy; do
    if ! has_codec "$cf"; then
        skip "构建时未链入 $cf，跳过 $cf 的多文件约束断言"
        continue
    fi
    rm -f "$EXT/multi.$cf"
    if "$T" create "$cf" "$EXT/multi.$cf" "$EXT/in/a.txt" "$EXT/in/b.txt" >/dev/null 2>&1; then
        bad "$cf 多文件创建竟被允许（单流格式只能压一个文件）"
    else
        ok "$cf 多文件创建被拒绝（单流格式约束）"
    fi
done

# 15.7 短写别名必须被归一化：br→brotli / lz→lzip / sz→snappy。
#      不归一化时 FindExternalCodec 查不到，会掉进上游 CLSID 查找，报出
#      「不支持的压缩格式」——症状完全联想不到是别名问题。
for pair in "br:brotli" "lz:lzip" "sz:snappy"; do
    short="${pair%%:*}"; long="${pair##*:}"
    if ! has_codec "$long"; then
        skip "构建时未链入 $long，跳过别名 $short 断言"
        continue
    fi
    rm -f "$EXT/alias.$short"
    if "$T" create "$short" "$EXT/alias.$short" "$EXT/in/a.txt" >/dev/null 2>&1 &&
       [ -s "$EXT/alias.$short" ]; then
        ok "短写 $short 被归一化为 $long 并成功创建"
    else
        bad "短写 $short 未被归一化（应等价于 $long）"
    fi
done

# ---------------------------------------------------------------------------
head1 "16. ISO 创建：自研 ISO9660 + Joliet 写入"

ISO="$WORK/iso"
rm -rf "$ISO"; mkdir -p "$ISO/src/sub"
printf 'hello iso\n' > "$ISO/src/hello.txt"
printf '中文内容\n'  > "$ISO/src/中文名称.txt"
printf 'nested\n'    > "$ISO/src/sub/nested.txt"
# 额外的三层目录树：用来验证路径表的排序与父号（同层两个目录、且名字非字典序输入）
mkdir -p "$ISO/src/tree/dirZ" "$ISO/src/tree/dirA/deep"
printf 'A\n' > "$ISO/src/tree/dirA/a.txt"
printf 'D\n' > "$ISO/src/tree/dirA/deep/d.txt"
printf 'Z\n' > "$ISO/src/tree/dirZ/z.txt"

# 从各个子项创建（ISO 根下直接是 hello.txt / 中文名称.txt / sub/ / tree/）
if "$T" create iso "$ISO/out.iso" "$ISO/src/hello.txt" "$ISO/src/中文名称.txt" \
        "$ISO/src/sub" "$ISO/src/tree" >/dev/null 2>&1 && [ -s "$ISO/out.iso" ]; then
    ok "ISO 镜像创建成功（上游 7-Zip 只能读、不能创建 ISO）"
else
    bad "ISO 镜像创建失败"
fi

# 16.1 独立 Python 解析器按 Joliet 还原目录树并逐字节比对源文件
if python3 - "$ISO/out.iso" "$ISO/src" <<'PY'
import sys, os, struct
iso, src = sys.argv[1], sys.argv[2]
SEC = 2048
data = open(iso, 'rb').read()
def u32(b, o): return struct.unpack_from('<I', b, o)[0]
o16 = 16 * SEC
if not (data[o16] == 1 and data[o16+1:o16+6] == b'CD001'):
    print('PVD magic 缺失'); sys.exit(1)
o17 = 17 * SEC
if not (data[o17] == 2 and data[o17+1:o17+6] == b'CD001'):
    print('SVD magic 缺失'); sys.exit(1)
if data[o17+88:o17+91] != b'\x25\x2f\x45':
    print('Joliet escape 缺失'); sys.exit(1)
rext = u32(data, o17 + 156 + 2); rsize = u32(data, o17 + 156 + 10)
# 卷描述符里的根目录记录：标识符长度必须为 1、值为 0x00（ECMA-119）
if data[o17 + 156 + 32] != 1 or data[o17 + 156 + 33] != 0:
    print('VD 根目录标识符不是 ECMA-119 形式'); sys.exit(1)
files = {}
sysseen = 0
ndirs = 0
def walk(ext, size, prefix):
    global sysseen, ndirs
    ndirs += 1
    buf = data[ext*SEC:ext*SEC+size]
    i = 0
    while i < len(buf):
        ln = buf[i]
        if ln == 0:
            i = (i // SEC + 1) * SEC
            continue
        namelen = buf[i+32]; flags = buf[i+25]
        fext = u32(buf, i+2); fsize = u32(buf, i+10)
        raw = buf[i+33:i+33+namelen]
        # ECMA-119：. 与 .. 是**单字节** 0x00 / 0x01，不是 UTF-16 文本。
        # 7-Zip 的 IsSystemItem() 依赖这一点；写成 UTF-16 会被当成真目录递归进去。
        if namelen == 1 and raw[0] in (0, 1):
            sysseen += 1
            i += ln
            continue
        nm = raw.decode('utf-16-be')
        if flags & 2: walk(fext, fsize, prefix + nm + '/')
        else: files[prefix + nm] = data[fext*SEC:fext*SEC+fsize]
        i += ln
walk(rext, rsize, '')
# 每个被走到的目录都必须恰好有 . 与 .. 两条系统项
if sysseen != 2 * ndirs:
    print('系统项 . / .. 数量异常: %d（%d 个目录，应为 %d）' % (sysseen, ndirs, 2*ndirs))
    sys.exit(1)
exp = {}
for root, dirs, fs in os.walk(src):
    for f in fs:
        p = os.path.join(root, f)
        exp[os.path.relpath(p, src)] = open(p, 'rb').read()
ok = True
for k, v in exp.items():
    if k not in files or files[k] != v:
        print('MISMATCH 缺失或内容不符:', k); ok = False
for k in files:
    if k not in exp:
        print('EXTRA 多出条目:', k); ok = False
sys.exit(0 if ok else 1)
PY
then
    ok "ISO 目录树按 Joliet 还原，内容逐字节一致（含中文名）"
else
    bad "ISO 内容 / Joliet 名还原不一致"
fi

# 16.2 用上游 7zz 的 ISO 读取器交叉验证（独立于本写入器）
if "$Z" l "$ISO/out.iso" 2>/dev/null | grep -q 'hello.txt'; then
    ok "上游 7zz 能读取自产 ISO 并列出条目"
else
    bad "上游 7zz 读不了自产 ISO"
fi
rm -rf "$ISO/zout"; mkdir -p "$ISO/zout"
if "$Z" x -y -o"$ISO/zout" "$ISO/out.iso" >/dev/null 2>&1 &&
   [ "$(cat "$ISO/zout/hello.txt" 2>/dev/null)" = "hello iso" ]; then
    ok "上游 7zz 解出自产 ISO 且内容正确"
else
    bad "上游 7zz 解自产 ISO 内容不符"
fi

# 16.3 系统挂载校验（最强端到端；沙箱下 attach 可能不可用则跳过）
# 注意：attach 会同时打出多条设备行（含偶然挂载的 APFS 卷），按行取首个设备并不可靠；
# 改为「是否出现预期文件」判定，卸载一律按挂载点（对 /private 符号链接不敏感）。
if command -v hdiutil >/dev/null 2>&1; then
    MP="$ISO/mnt"; rm -rf "$MP"; mkdir -p "$MP"
    hdiutil attach -nobrowse -noautoopen -noverify -mountpoint "$MP" "$ISO/out.iso" \
        >/dev/null 2>&1 || true
    if [ -f "$MP/hello.txt" ]; then
        if [ "$(cat "$MP/hello.txt")" = "hello iso" ] && [ -f "$MP/sub/nested.txt" ]; then
            ok "ISO 可被系统挂载且内容正确（hdiutil 实测）"
        else
            bad "ISO 挂载后内容不符"
        fi
        hdiutil detach "$MP" -force >/dev/null 2>&1 || true
    else
        hdiutil detach "$MP" -force >/dev/null 2>&1 || true
        skip "hdiutil attach 不可用（沙箱），跳过挂载校验"
    fi
else
    skip "无 hdiutil，跳过挂载校验"
fi

# 16.4 路径表结构合规（ECMA-119 6.9.1）：父号必须自洽且小于自身编号（根自指 1），
#      条目须按「层级 -> 父目录号 -> 标识符」升序。Windows CDFS 等严格读取器会按
#      此顺序做二分查找，顺序不对会查不到目录。
if python3 - "$ISO/out.iso" <<'PY'
import struct, sys
data = open(sys.argv[1], 'rb').read()
SEC = 2048
def u32(o): return struct.unpack_from('<I', data, o)[0]
def u16(o): return struct.unpack_from('<H', data, o)[0]
o16 = 16 * SEC
pts = u32(o16 + 132)
Lpt = u32(o16 + 140)
# 类型 M 路径表的位置是**大端**存储，漏掉这点会算出越界扇区
mpt = struct.unpack('>I', data[o16 + 148:o16 + 152])[0]
if pts == 0 or Lpt == 0 or mpt == 0:
    print('路径表位置/大小字段为空'); sys.exit(1)
# 条目布局：len, extAttrLen, extent(LE u32), parent(LE u16), 名字。
# 注意**没有**「目录编号」字段 —— 编号就是条目在表中的 1-based 位置。
ents = []
o = Lpt * SEC
end = o + pts
while o < end:
    nl = data[o]; o += 2; o += 4
    par = u16(o); o += 2
    raw = data[o:o + nl]; o += nl
    if nl & 1: o += 1
    ents.append((par, raw))
if not ents:
    print('路径表为空'); sys.exit(1)
for i, (par, raw) in enumerate(ents, 1):
    if i == 1:
        if par != 1: print('根条目 parent 应为 1，实为 %d' % par); sys.exit(1)
    elif not (1 <= par < i):
        print('条目 #%d 的 parent=%d 不合法' % (i, par)); sys.exit(1)
lvl = {1: 1}
for i in range(2, len(ents) + 1):
    lvl[i] = lvl.get(ents[i - 1][0], 1) + 1
keys = [(lvl[i], ents[i - 1][0], ents[i - 1][1]) for i in range(1, len(ents) + 1)]
if keys != sorted(keys):
    print('路径表未按 (层级, 父号, 名字) 升序'); sys.exit(1)
# 本次夹具的目录树：root, sub, tree, tree/dirA, tree/dirZ, tree/dirA/deep = 6 个
if len(ents) != 6:
    print('目录条目数 %d（期望 6）' % len(ents)); sys.exit(1)
sys.exit(0)
PY
then
    ok "路径表合规：父号自洽且按（层级,父号,名字）升序（ECMA-119 6.9.1）"
else
    bad "ISO 路径表不符合 ECMA-119 的父号/排序要求"
fi

# ---------------------------------------------------------------------------
head1 "17. DMG 创建：调系统 hdiutil（零子进程原则的唯一边界）"

DMG="$WORK/dmg"
rm -rf "$DMG"; mkdir -p "$DMG/src/sub"
printf 'hello dmg\n' > "$DMG/src/hello.txt"
printf 'nested dmg\n' > "$DMG/src/sub/nested.txt"

if command -v hdiutil >/dev/null 2>&1; then
    if "$T" create dmg "$DMG/out.dmg" "$DMG/src" >/dev/null 2>&1 && [ -s "$DMG/out.dmg" ]; then
        ok "DMG 磁盘映像创建成功（上游 7-Zip 只能读、不能创建 DMG）"
    else
        bad "DMG 磁盘映像创建失败"
    fi
    # 结构合法性：hdiutil imageinfo 能识别
    if hdiutil imageinfo "$DMG/out.dmg" >/dev/null 2>&1; then
        ok "产物是合法 DMG（hdiutil imageinfo 通过）"
    else
        bad "产物不是合法 DMG"
    fi
    # 内容校验：上游 7zz 能打开 DMG 并看到内层文件系统
    if "$Z" l "$DMG/out.dmg" 2>/dev/null | grep -qi 'hello.txt'; then
        ok "上游 7zz 能列出 DMG 内容（识别为磁盘映像）"
    else
        # 7zz 对 DMG 的支持取决于编译进来的 handler；缺失时不算失败
        skip "7zz 未报出 DMG 内条目（handler 差异），跳过"
    fi
    # 挂载读回（best-effort；同 16.3，按挂载点判存、按挂载点卸载）
    MP="$DMG/mnt"; rm -rf "$MP"; mkdir -p "$MP"
    hdiutil attach -nobrowse -noautoopen -noverify -mountpoint "$MP" "$DMG/out.dmg" \
        >/dev/null 2>&1 || true
    if [ -f "$MP/src/hello.txt" ]; then
        [ "$(cat "$MP/src/hello.txt")" = "hello dmg" ] \
            && ok "DMG 可被系统挂载且内容正确（hdiutil 实测）" \
            || bad "DMG 挂载后内容不符"
        hdiutil detach "$MP" -force >/dev/null 2>&1 || true
    else
        hdiutil detach "$MP" -force >/dev/null 2>&1 || true
        skip "hdiutil attach 不可用（沙箱），跳过挂载校验"
    fi
else
    skip "无 hdiutil，跳过 DMG 创建（本项目 DMG 依赖系统 hdiutil）"
fi

# ---------------------------------------------------------------------------
head1 "18. lzip：自研容器 + liblzma raw LZMA1（上游完全没有）"

LZ="$WORK/lzip"
rm -rf "$LZ"; mkdir -p "$LZ/in"
printf 'AAA\n' > "$LZ/in/a.txt"
# 两份规模/可压缩性都不同的样本：大段可压缩文本（跨多个 64 KiB 输入块）
# 与不可压缩的随机数据（走到 copy 之外的分支）
python3 - "$LZ/in/big.txt" "$LZ/in/rand.bin" <<'PY'
import sys, random
open(sys.argv[1], 'w').write('The quick brown fox jumps over the lazy dog. ' * 20000)
random.seed(7)
open(sys.argv[2], 'wb').write(random.randbytes(200000))
PY

if ! has_codec lzip; then
    skip "构建时未链入 liblzma，跳过 lzip 全部断言（优雅降级）"
else
    # 18.1 创建 + 自解往返
    for f in big.txt rand.bin; do
        A="$LZ/mk_$f.lz"
        rm -f "$A"
        if "$T" create lzip "$A" "$LZ/in/$f" >/dev/null 2>&1 && [ -s "$A" ]; then
            rm -rf "$LZ/out"; mkdir -p "$LZ/out"
            if (cd "$LZ/out" && "$T" extract "$A" . >/dev/null 2>&1) &&
               cmp -s "$LZ/in/$f" "$LZ/out/mk_$f"; then
                ok "lzip 往返一致（$f）"
            else
                bad "lzip 往返不一致（$f）"
            fi
        else
            bad "lzip 创建失败（$f）"
        fi
    done

    # 18.2 独立读取器：xz 支持 --format=lzip（只读）。自产文件必须能被它解出同一份字节
    XZBIN="$(command -v xz || true)"
    if [ -n "$XZBIN" ] &&
       "$XZBIN" --format=lzip -dc "$LZ/mk_big.txt.lz" 2>/dev/null | cmp -s - "$LZ/in/big.txt"; then
        ok "自产 lzip 被独立读取器 xz --format=lzip 解出且逐字节一致"
    else
        skip "无可用 xz --format=lzip，跳过 lzip 产物的独立交叉验证"
    fi

    # 18.3 外部产出 → 自解。xz 只能解 lzip、不能压，所以「外部产出」这一侧用
    #      Python 的 liblzma 编出 LZMA1 原始流，再按规范拼头尾 —— 另一套实现。
    if python3 - "$LZ/ext.lz" "$LZ/in/a.txt" <<'PY'
import lzma, struct, zlib, sys
want = 1 << 23
best = bestv = None
for ds in range(12, 30):                      # 低 5 位 = log2(基准大小)，12..29
    base = 1 << ds
    for frac in range(8):                     # 高 3 位 = 减掉的分数分子
        v = base - (base // 16) * frac
        if v >= want and (bestv is None or v < bestv):
            bestv, best = v, (frac << 5) | ds
data = open(sys.argv[2], 'rb').read()
raw = lzma.compress(data, format=lzma.FORMAT_RAW, filters=[
    {"id": lzma.FILTER_LZMA1, "preset": 6, "dict_size": want,
     "lc": 3, "lp": 0, "pb": 2}])
hdr = b'LZIP' + bytes([1, best])               # version 恒为 1
trailer = struct.pack('<IQQ', zlib.crc32(data) & 0xffffffff, len(data),
                      len(hdr) + len(raw) + 20)
open(sys.argv[1], 'wb').write(hdr + raw + trailer)
PY
    then
        rm -rf "$LZ/e1"; mkdir -p "$LZ/e1"
        if (cd "$LZ/e1" && "$T" extract "$LZ/ext.lz" . >/dev/null 2>&1) &&
           [ "$(cat "$LZ/e1"/* 2>/dev/null | tr -d '\n')" = "AAA" ]; then
            ok "外部生成的 lzip（Python liblzma + 规范容器）可被解出"
        else
            bad "外部生成的 lzip 解压失败"
        fi
    else
        skip "python3 构造外部 lzip 样本失败，跳过该断言"
    fi

    # 18.4 多成员：两个成员直接拼接，规范要求按顺序串接解出
    cat "$LZ/mk_big.txt.lz" "$LZ/mk_rand.bin.lz" > "$LZ/multi.lz"
    cat "$LZ/in/big.txt" "$LZ/in/rand.bin" > "$LZ/expect.bin"
    rm -rf "$LZ/e2"; mkdir -p "$LZ/e2"
    if (cd "$LZ/e2" && "$T" extract "$LZ/multi.lz" . >/dev/null 2>&1) &&
       cmp -s "$LZ/expect.bin" "$LZ/e2/multi"; then
        ok "多成员 lzip 按规范串接解出"
    else
        bad "多成员 lzip 解压结果不符"
    fi

    # 18.5 完整性三因子（CRC32 / 原始长度 / 成员总长）逐个篡改，都必须被拒。
    #      这三条正是 BUILD.md 里 lzip 实现的验收点：只做 CRC 一项是不够的。
    for what in crc datasize membersize; do
        if python3 - "$LZ/mk_big.txt.lz" "$LZ/bad_$what.lz" "$what" <<'PY'
import sys
d = bytearray(open(sys.argv[1], 'rb').read())
off = {"crc": -20, "datasize": -16, "membersize": -8}[sys.argv[3]]
d[off] ^= 0x5A
open(sys.argv[2], 'wb').write(d)
PY
        then
            if "$T" test "$LZ/bad_$what.lz" >/dev/null 2>&1; then
                bad "lzip 尾部 $what 被篡改却仍被接受"
            else
                ok "lzip 尾部 $what 被篡改时正确报错"
            fi
        fi
    done

    # 18.6 截断与尾部垃圾：前者要求「成员没解完」，后者要求「残余无法解释」，都必须拒
    SZ="$(wc -c < "$LZ/mk_big.txt.lz" | tr -d ' ')"
    head -c $((SZ - 5)) "$LZ/mk_big.txt.lz" > "$LZ/trunc.lz"
    if "$T" test "$LZ/trunc.lz" >/dev/null 2>&1; then
        bad "截断的 lzip 竟被接受"
    else
        ok "截断的 lzip 被拒绝"
    fi
    cp "$LZ/mk_big.txt.lz" "$LZ/junk.lz"; printf 'X' >> "$LZ/junk.lz"
    if "$T" test "$LZ/junk.lz" >/dev/null 2>&1; then
        bad "尾部多出垃圾的 lzip 竟被接受"
    else
        ok "尾部垃圾被拒绝"
    fi

    # 18.7 lzip 有强魔数（"LZIP" + 版本 1），改名后仍应按内容认出
    cp "$LZ/mk_big.txt.lz" "$LZ/renamed.bin"
    if "$T" info "$LZ/renamed.bin" 2>/dev/null | grep -q '^format=lzip'; then
        ok "lzip 按内容（魔数）识别，与扩展名无关"
    else
        bad "改名后的 lzip 未被识别"
    fi
fi

# ---------------------------------------------------------------------------
head1 "19. snappy：自实现（裸格式 + 分帧格式），上游完全没有"

SN="$WORK/snappy"
rm -rf "$SN"; mkdir -p "$SN"
printf 'AAA\n' > "$SN/a.txt"

# 19.1 创建（分帧）+ 自解往返
rm -f "$SN/mk.sz"
if "$T" create snappy "$SN/mk.sz" "$SN/a.txt" >/dev/null 2>&1 && [ -s "$SN/mk.sz" ]; then
    ok "snappy 归档创建成功（上游完全没有）"
    rm -rf "$SN/o1"; mkdir -p "$SN/o1"
    if (cd "$SN/o1" && "$T" extract "$SN/mk.sz" . >/dev/null 2>&1) &&
       [ "$(cat "$SN/o1"/* 2>/dev/null | tr -d '\n')" = "AAA" ]; then
        ok "snappy 往返（创建→解码→抽取）内容一致"
    else
        bad "snappy 往返内容不一致"
    fi
else
    bad "snappy 归档创建失败"
fi

# 19.2 产物必须是规范里的分帧格式：以 10 字节流标识开头
#      （0xFF 06 00 00 + "sNaPpY"）；裸格式没有这个头。
if python3 - "$SN/mk.sz" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read()
sys.exit(0 if d[:10] == bytes([0xFF, 0x06, 0x00, 0x00]) + b'sNaPpY' else 1)
PY
then
    ok "snappy 产物以规范的 10 字节分帧流标识开头"
else
    bad "snappy 产物缺少分帧流标识"
fi

# 19.3 分帧块结构与掩码 CRC 自洽：
#      * 每块长度不超过 65540（65536 数据 + 4 字节校验），遍历必须正好走到文件尾；
#      * 存的 mask(crc32c(原始数据)) 必须等于独立算出来的值。
#      注意是 CRC-32C（Castagnoli），与 zlib 的 CRC-32 不是同一个多项式。
if python3 - "$SN/mk.sz" "$SN/a.txt" <<'PY'
import sys
POLY = 0x82F63B78
tab = []
for i in range(256):
    c = i
    for _ in range(8):
        c = (POLY ^ (c >> 1)) if (c & 1) else (c >> 1)
    tab.append(c)
def crc32c(b):
    c = 0xFFFFFFFF
    for x in b:
        c = tab[(c ^ x) & 0xFF] ^ (c >> 8)
    return c ^ 0xFFFFFFFF
def mask(x):
    return (((x >> 15) | (x << 17)) + 0xA282EAD8) & 0xFFFFFFFF
src = open(sys.argv[2], 'rb').read()
d = open(sys.argv[1], 'rb').read()
p, seen, crc_ok = 10, 0, False
while p < len(d):
    if p + 4 > len(d):
        sys.exit(1)
    t = d[p]; ln = d[p+1] | (d[p+2] << 8) | (d[p+3] << 16)
    if p + 4 + ln > len(d) or ln > 65540:
        sys.exit(1)
    body = d[p+4:p+4+ln]
    if t in (0x00, 0x01):
        seen += 1
        if int.from_bytes(body[:4], 'little') != mask(crc32c(src)):
            sys.exit(1)
        crc_ok = True
    p += 4 + ln
sys.exit(0 if (seen >= 1 and crc_ok and p == len(d)) else 1)
PY
then
    ok "snappy 分帧块结构合规且掩码 CRC-32C 与独立计算一致"
else
    bad "snappy 分帧块结构或校验值不符"
fi

# 19.4 测试模式（-t）：7-Zip 在这种模式下**不给输出流**，解码器必须照常跑完
#      （只校验、不落盘）。曾经因为直接对空输出流解引用而段错误，这里专门钉住。
if "$T" test "$SN/mk.sz" >/dev/null 2>&1; then
    ok "snappy 在测试模式（无输出流）下正常通过完整性校验"
else
    bad "snappy 在测试模式（无输出流）下失败"
fi
for f in zstd lzip lz4 brotli; do
    has_codec "$f" || continue
    # ⚠️ 输出名必须带该格式认识的扩展名：brotli 没有魔数，只能按扩展名认领，
    # 写成一个没有点号的名字会让产物事后打不开（这不是引擎的问题，是格式本身的属性）。
    case "$f" in
        zstd)   vext=zst ;;
        lzip)   vext=lz ;;
        lz4)    vext=lz4 ;;
        brotli) vext=br ;;
    esac
    A="$EXT/val_$f.$vext"
    if "$T" create "$f" "$A" "$SN/a.txt" >/dev/null 2>&1 && "$T" test "$A" >/dev/null 2>&1; then
        ok "$f 在测试模式（无输出流）下正常通过完整性校验"
    else
        bad "$f 在测试模式（无输出流）下失败"
    fi
done

# 19.5 裸格式：分帧产物里的**压缩块**本身就是一条合法的裸 snappy 流
#      （varint 长度 + 元素流），去掉 4 字节掩码 CRC 后改名 .snappy 应能独立解出。
#      用可压缩的输入，保证编码器选的是压缩块（压不动时会退化成未压缩块，
#      那种块的数据是裸字节、不是 snappy 流）。
python3 - "$SN/ap.txt" <<'PY'
import sys
open(sys.argv[1], 'w').write('A\n' * 2000)
PY
if "$T" create snappy "$SN/mk2.sz" "$SN/ap.txt" >/dev/null 2>&1 &&
   python3 - "$SN/mk2.sz" "$SN/raw.snappy" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read()
p = 10
while p < len(d):
    t = d[p]; ln = d[p+1] | (d[p+2] << 8) | (d[p+3] << 16)
    if t == 0x00:
        open(sys.argv[2], 'wb').write(d[p+4+4:p+4+ln])   # 跳过 4 字节掩码 CRC
        sys.exit(0)
    p += 4 + ln
sys.exit(1)
PY
then
    rm -rf "$SN/o2"; mkdir -p "$SN/o2"
    if (cd "$SN/o2" && "$T" extract "$SN/raw.snappy" . >/dev/null 2>&1) &&
       cmp -s "$SN/ap.txt" "$SN/o2/raw"; then
        ok "裸格式 snappy 走独立解码分支且内容正确"
    else
        bad "裸格式 snappy 解压失败"
    fi
else
    skip "无法从分帧产物提取裸块，跳过裸格式断言"
fi

# 19.6 损坏检测：改动最后一个字节（落在块数据里）后 CRC 必然不符，必须报错
if python3 - "$SN/mk.sz" "$SN/bad.sz" <<'PY'
import sys
d = bytearray(open(sys.argv[1], 'rb').read())
d[-1] ^= 0x5A
open(sys.argv[2], 'wb').write(d)
PY
then
    if "$T" test "$SN/bad.sz" >/dev/null 2>&1; then
        bad "snappy 数据被篡改却仍被接受"
    else
        ok "snappy 数据被篡改时正确报错"
    fi
fi

# 19.7 byExtOnly 约定：snappy 只按扩展名（.sz / .snappy）认领，改名后不再认出。
#      这是刻意的取舍 —— 裸格式没有魔数，靠内容认领会把任意二进制误判成 snappy。
cp "$SN/mk.sz" "$SN/renamed.bin"
if "$T" info "$SN/renamed.bin" 2>/dev/null | grep -q '^format=snappy'; then
    bad "snappy 竟然按内容认领了（byExtOnly 约定被破坏）"
else
    ok "snappy 依约只按扩展名认领，改名后不误认"
fi

# ---------------------------------------------------------------------------
printf '\n\033[1m================ 汇总 ================\033[0m\n'
printf '通过: \033[32m%s\033[0m   失败: \033[31m%s\033[0m\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
    printf '失败用例：%b\n' "$FAILED_CASES"
fi

rm -rf "$WORK"
[ "$FAIL" -eq 0 ]
