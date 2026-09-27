# ---------------------------------------------------------------------------
# MODIFIED FOR THE macOS PORT - 2026-09-21
#   This file is NOT byte-identical to upstream 7-Zip 26.03.
#   Change: macOS native semantic support (Unicode NFD normalization) needs CoreFoundation
#   All other upstream code is untouched. The byte-exact change set is
#   dist/build/upstream-macos.patch in https://github.com/XINKEJU/7-Zip-macOS
#   7-Zip Copyright (C) 1999-2026 Igor Pavlov.
#   Licensed under GNU LGPL-2.1-or-later with the unRAR license restriction.
# ---------------------------------------------------------------------------

PLATFORM=arm64
O=b/m_$(PLATFORM)
IS_X64=
IS_X86=
IS_ARM64=1
CROSS_COMPILE=
#use this code to reduce features
MY_ARCH=-arch arm64 -march=armv8-a
MY_ARCH=-arch arm64
USE_ASM=1
CC=$(CROSS_COMPILE)clang
CXX=$(CROSS_COMPILE)clang++
USE_CLANG=1

# macOS native semantic support (Unicode NFD normalization) needs CoreFoundation
MY_LIBS = -framework CoreFoundation
