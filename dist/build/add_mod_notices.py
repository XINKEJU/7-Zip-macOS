#!/usr/bin/env python3
"""给被 macOS 移植补丁修改过的上游源文件插入「已修改 + 日期」声明。

LGPL-2.1 §1 要求被修改的文件带 prominent notice，说明改动内容与日期。
本脚本只做插桩，不改动任何既有行；插桩后再由 regen_upstream_patch.sh 重生成补丁。

⚠️ 行尾必须原样保持：上游 7-Zip 源码整棵树是 CRLF。曾经用 text 模式读写，
把 8 个文件静默转成了 LF，重生成的补丁于是变成「整文件替换」（14 KB → 373 KB）。
所以这里一律按字节读、按原行尾写。
"""
import sys
import textwrap
from pathlib import Path

SRC = Path(sys.argv[1])
MARKER = "MODIFIED FOR THE macOS PORT"

TOP = """{c} ---------------------------------------------------------------------------
{c} MODIFIED FOR THE macOS PORT - {date}
{c}   This file is NOT byte-identical to upstream 7-Zip 26.03.
{body}
{c}   All other upstream code is untouched. The byte-exact change set is
{c}   dist/build/upstream-macos.patch in https://github.com/XINKEJU/7-Zip-macOS
{c}   7-Zip Copyright (C) 1999-2026 Igor Pavlov.
{c}   Licensed under GNU LGPL-2.1-or-later with the unRAR license restriction.
{c} ---------------------------------------------------------------------------
"""

# (相对路径, 日期, 改动说明, 插在首行之后?) .mak/.gcc 插在最前，C/C++ 插在首行注释之后
TARGETS = [
    ("CPP/Common/StringConvert.cpp", "2026-09-22", "//",
     "non-UTF-8 byte strings are decoded as GB18030, so file names in ZIP "
     "archives produced on Chinese Windows are not mangled", True),
    ("CPP/7zip/UI/Common/ExtractingFilePath.cpp", "2026-09-21", "//",
     "extracted paths are normalized to Unicode NFD on macOS, matching the "
     "form the native file system and Spotlight already use", True),
    ("CPP/7zip/UI/Common/ArchiveExtractCallback.cpp", "2026-09-21", "//",
     "the macOS quarantine attribute is propagated to extracted files", True),
    ("CPP/7zip/UI/Common/ArchiveExtractCallback.h", "2026-09-21", "//",
     "declares the quarantine-propagation hook used by the .cpp above", True),
    ("CPP/7zip/7zip_gcc.mak", "2026-09-21", "#",
     "adds a compile rule for MacOsNative.o", False),
    ("CPP/7zip/Bundles/Alone2/makefile.gcc", "2026-09-21", "#",
     "links MacOsNative.o into the 7zz target", False),
    ("CPP/7zip/var_mac_arm64.mak", "2026-09-21", "#",
     "macOS native semantic support (Unicode NFD normalization) needs "
     "CoreFoundation", False),
    ("CPP/7zip/var_mac_x64.mak", "2026-09-21", "#",
     "macOS native semantic support (Unicode NFD normalization) needs "
     "CoreFoundation", False),
]


def make_banner(date: str, c: str, desc: str, nl: str) -> str:
    lines = textwrap.wrap(desc, width=96)
    body = f"{c}   Change: {lines[0]}"
    for extra in lines[1:]:
        body += f"{nl}{c}     {extra}"
    return TOP.format(c=c, date=date, body=body).replace("\n", nl)


for rel, date, c, desc, after_first_line in TARGETS:
    p = SRC / rel
    raw = p.read_bytes().decode("utf-8")
    if MARKER in raw:
        print(f"   已有声明，跳过：{rel}")
        continue
    nl = "\r\n" if "\r\n" in raw else "\n"
    banner = make_banner(date, c, desc, nl)
    if after_first_line:
        cut = raw.index("\n") + 1
        raw = raw[:cut] + nl + banner + raw[cut:]
    else:
        raw = banner + nl + raw
    p.write_bytes(raw.encode("utf-8"))
    print(f"   已插入声明：{rel}（行尾 {nl!r}）")
