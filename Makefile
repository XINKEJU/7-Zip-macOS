# ===========================================================================
# 7-Zip 26.03 macOS port — top level build
#
#   make            engine -> enginebin -> app -> pkg     (default)
#   make help       list every target
#
# 架构：**只构建 arm64**（Apple Silicon）。此前是 arm64 + x86_64 双切片 lipo
# 合成的通用二进制，2026-09-24 起放弃 Intel 支持——两个切片里 x86_64 那一半
# 占了可执行体体积的近一半，而 Intel Mac 已无在售机型。上游源码保持原样，
# 只是不再编译 cmpl_mac_x64.mak。若要恢复，把下面各步的 x86_64 分支加回来即可
# （git 历史里有原样实现）。
#
# Every step reproduces exactly what dist/build/BUILD.md documents. Read that
# file before changing anything here: it records the pitfalls that make the
# obvious commands fail (macOS-only makefiles, deployment target, the ordering
# constraint between the app's ad-hoc re-seal and the Quick Look extension).
#
# Prerequisites: macOS 11+, Xcode Command Line Tools, GNU make.
# ===========================================================================

SHELL := /bin/sh

ROOT    := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
# 上游源码目录由 dist/build/upstream_dir.sh 解析（优先 $Z7_SRC，否则取版本号最高
# 的 7zXXXX-src/）。这样升级上游只需运行 upgrade_upstream.sh，不必来改这里 ——
# 以前这个字符串硬编码在 5 个文件里，漏改一处的症状是"找不到某个上游文件"，
# 很难联想到是升级没做全。
SRC     := $(shell sh $(ROOT)/dist/build/upstream_dir.sh)
DIST    := $(ROOT)/dist
BUNDLE  := $(SRC)/CPP/7zip/Bundles/Alone2
BUILD   := $(DIST)/build
ENGINE  := $(BUILD)/7zz
ICNS    := $(DIST)/app-res/7zip.icns
APP     := $(DIST)/7-Zip.app
APPEX   := $(APP)/Contents/PlugIns/7ZipQuickLook.appex

# Parallelism for the upstream makefiles. Override with: make JOBS=4
JOBS    ?= $(shell sysctl -n hw.ncpu 2>/dev/null || echo 4)

# Minimum macOS version of the produced binaries. 11.0 is the first release
# that runs on Apple Silicon. Without this the deployment target silently
# becomes the build machine's SDK version and the binaries refuse to launch on
# anything older.
DEPLOY  ?= 11.0

VERSION := 26.03

.DEFAULT_GOAL := all
.PHONY: all engine enginebin dylib bridge app ql pkg tarball test objc-test appcheck verify check upstream upstream-patch upstream-patch-regen clean distclean help

# ---------------------------------------------------------------------------
# all — the default pipeline
# ---------------------------------------------------------------------------
all: pkg

# ---------------------------------------------------------------------------
# engine — compile the upstream engine executable for arm64
#
# NOTE: upstream's makefiles use plain timestamp rules. If a stale object file
# survives a deletion (macOS security policy can block bulk rm), make will
# consider the target up to date and skip recompiling *silently*. If a change
# seems to have no effect, run `make distclean` first, or add -B below.
# ---------------------------------------------------------------------------
engine:
	@printf '==> 1/4 编译 arm64 引擎\n'
	cd '$(BUNDLE)' && MACOSX_DEPLOYMENT_TARGET=$(DEPLOY) $(MAKE) -j$(JOBS) -f ../../cmpl_mac_arm64.mak

# ---------------------------------------------------------------------------
# enginebin — stage the compiled engine as dist/build/7zz and ad-hoc sign it
#
# This target used to be called `universal`: the engine was a fat binary lipo'd
# from arm64 + x86_64 slices. Now that only arm64 is shipped there is nothing to
# lipo — the step degenerates to copy + sign — and the old name would keep
# claiming a fact that is no longer true.
#
# The re-sign is mandatory, not cosmetic: the kernel refuses to execute an
# unsigned arm64 binary.
# ---------------------------------------------------------------------------
enginebin: engine
	@printf '==> 2/4 取出引擎可执行体\n'
	@mkdir -p '$(BUILD)'
	cp -f '$(BUNDLE)/b/m_arm64/7zz' '$(ENGINE)'
	codesign --force --sign - --timestamp=none '$(ENGINE)'
	@lipo -archs '$(ENGINE)' | sed 's/^/   架构: /'
	@codesign --verify --strict '$(ENGINE)' && echo '   签名校验通过'

# ---------------------------------------------------------------------------
# dylib / bridge — the embedded engine and the glue the app links against
#
#   dylib    lib7z.dylib: the engine built as a shared library (Format7zF).
#            This is the LGPL "replaceable library": the app loads it at
#            runtime from Contents/Frameworks, so a user may substitute it.
#   bridge   lib7zbridge.a + lib7zbridgeobjc.a: the C++ / ObjC++ layer that
#            exposes the engine to the AppKit front end.
#
# NOTE: build_dylib.sh uses `make -B` rather than deleting b/. A security
# hook can block bulk `rm -rf`, which silently left the old artifact in place
# and made script edits appear to have no effect.
# ---------------------------------------------------------------------------
dylib:
	@printf '==> 构建内嵌引擎动态库\n'
	sh '$(DIST)/engine/build_dylib.sh'

bridge: dylib
	@printf '==> 构建桥接层（C++ / ObjC++）\n'
	sh '$(DIST)/engine/build_engine.sh'

# ---------------------------------------------------------------------------
# app — assemble 7-Zip.app, which also builds the Quick Look extension.
#
# build_app.sh re-seals the bundle with --deep *before* invoking the extension
# build, because --deep would otherwise strip the extension's sandbox
# entitlement and ExtensionKit would refuse to register it.
# ---------------------------------------------------------------------------
app: enginebin bridge
	@printf '==> 3/4 组装应用与 Quick Look 扩展\n'
	sh '$(DIST)/app-src/build_app.sh' '$(ICNS)' '$(DIST)'

# Rebuild the extension alone, against an already assembled application.
ql: enginebin
	APP_BUNDLE='$(APP)' sh '$(DIST)/ql-src/build_ql.sh'

# ---------------------------------------------------------------------------
# test — bridge and adapter verification, then the assembled bundle
#
#   test        lib7zbridge 验收（对照官方 7zz 逐项比对）
#   objc-test   Objective-C 适配层验收（App 实际调用的那一层）
#   appcheck    打包产物验收：动态库解析、部署目标、签名、真实启动
#               （`make check` 之前跑这个，它能挡住"库改了但包没更新"、
#                install_name 与文件名不一致这类只在运行期暴露的问题）
# ---------------------------------------------------------------------------
test:
	@printf '==> 构建并运行桥接层验收\n'
	sh '$(DIST)/tests/build_test.sh'
	sh '$(DIST)/tests/verify_engine.sh'

objc-test: bridge
	@printf '==> 构建并运行 ObjC 适配层验收\n'
	sh '$(DIST)/tests/build_objc_test.sh'
	WORK="$$(mktemp -d "$${TMPDIR:-/tmp}/z7objc.XXXXXX")" && \
	    '$(DIST)/tests/objc_test' "$$WORK"; st=$$?; rm -rf "$$WORK"; exit $$st

appcheck:
	@printf '==> 应用包验收\n'
	sh '$(DIST)/tests/verify_app.sh' '$(APP)'

# ---------------------------------------------------------------------------
# pkg — integrated installer, disk image, CLI archive and checksums
# ---------------------------------------------------------------------------
pkg: app
	@printf '==> 4/4 生成安装包\n'
	sh '$(BUILD)/make_installer.sh'

# ---------------------------------------------------------------------------
# tarball — the distribution tree consumed by the Homebrew formula
# ---------------------------------------------------------------------------
tarball: enginebin
	sh '$(BUILD)/package.sh'

# ---------------------------------------------------------------------------
# verify — checks the install/uninstall logic and the Homebrew formula.
#
# Needs no privileges, but it is NOT artifact-free: verify_scripts.sh reads the
# real .pkg payload and the two installer scripts under dist/build/.installer/,
# and verify_formula.sh reads the published tarball.
#
# It deliberately does NOT depend on pkg/tarball. verify exists to check the
# artefacts that were actually built and published -- rebuilding them first
# would re-stamp the archives (pkgbuild writes fresh timestamps), silently
# changing every hash and making the checksum/formula comparison meaningless.
# So it only asserts that the prerequisites are present, and fails fast with an
# actionable message instead of a cascade of "missing file" errors.
# ---------------------------------------------------------------------------
VERIFY_NEEDS := $(DIST)/7-Zip-$(VERSION)-macOS.pkg \
                $(BUILD)/.installer/scripts-cli/postinstall \
                $(BUILD)/.installer/scripts-app/postinstall \
                $(DIST)/7zip-macos-$(VERSION)-macos-arm64.tar.gz

verify:
	@missing=0; for f in $(VERIFY_NEEDS); do \
	    [ -e "$$f" ] || { printf 'verify: 缺少 %s\n' "$$f"; missing=1; }; \
	done; \
	if [ "$$missing" -ne 0 ]; then \
	    printf '\n校验要对着真正构建出来的产物做，请先执行:  make pkg tarball\n'; \
	    exit 1; \
	fi
	@printf '==> 安装与卸载脚本逻辑\n'
	sh '$(BUILD)/verify_scripts.sh'
	@printf '\n==> Homebrew 公式一致性\n'
	sh '$(DIST)/homebrew/verify_formula.sh'

# ---------------------------------------------------------------------------
# check — verify, plus integrity of the artifacts that are actually on disk
# ---------------------------------------------------------------------------
check: verify
	@printf '\n==> 产物校验和\n'
	cd '$(DIST)' && shasum -a 256 -c checksums.txt
	@printf '\n==> DMG 完整性\n'
	hdiutil verify -quiet '$(DIST)/7-Zip-$(VERSION)-macOS.dmg' && echo '    DMG checksum VALID'
	@printf '\n==> 应用签名\n'
	codesign --verify --deep --strict '$(APP)' && echo '   7-Zip.app 签名校验通过'

# ---------------------------------------------------------------------------
# upstream — 把上游引擎升级到指定版本
#
# 下载官方源码 → 校验（xz 完整性 / 版本号 / 结构）→ 解包到 7zXXXX-src/
# → 自动施加本移植的 macOS 补丁。**不会**删除旧源码树（打印 git rm 命令由人执行），
# 也不会碰 pkg/tarball。
#
# 用法: make upstream NEW=26.04          只做升级（含补丁）
#       make upstream NEW=26.04 GATE=1   升级后立刻重建引擎并跑全部门禁
# ---------------------------------------------------------------------------
upstream:
	@if [ -z '$(NEW)' ]; then \
	    printf '用法: make upstream NEW=<版本号> [GATE=1]\n  例如: make upstream NEW=26.04 GATE=1\n'; \
	    exit 2; \
	fi
	sh '$(ROOT)/dist/build/upgrade_upstream.sh' '$(NEW)' $(if $(GATE),--gate,)

# ---------------------------------------------------------------------------
# upstream-patch — 校验当前上游源码树是否已带上本移植的 macOS 补丁
#
# 补丁是承重的（GB18030 文件名解码 / NFD 规范化 / 隔离属性传播），缺了它
# **构建照样成功但行为悄悄退化**。build_dylib.sh 每次构建前也会自动校验一次，
# 这个目标用于单独复核。
# ---------------------------------------------------------------------------
upstream-patch:
	sh '$(ROOT)/dist/build/apply_upstream_patch.sh' '$(SRC)' --check
	@printf '\n补丁清单（%s）：\n' '$(notdir $(SRC))'
	@grep '^diff -ruN a/' '$(ROOT)/dist/build/upstream-macos.patch' | sed 's|^diff -ruN a/||;s| b/.*||' | sed 's/^/   /'

# ---------------------------------------------------------------------------
# upstream-patch-regen — 由「官方原版源码」重新生成 macOS 补丁
#
# **改过上游源码树就必须跑一次**。补丁与树一旦分叉，升级上游时施加的是旧改动，
# 而 --check 的标记仍在，问题看不出来。脚本自带自校验：把新补丁施加到干净原版上，
# 要求结果与当前工作树逐字节一致；并用固定时间戳保证补丁文件本身可复现。
#
# 需要一个干净的原版树：
#   tar -xJf 7z2603-src.tar.xz -C /tmp/z7pristine
#   make upstream-patch-regen PRISTINE=/tmp/z7pristine
# ---------------------------------------------------------------------------
upstream-patch-regen:
	@if [ -z '$(PRISTINE)' ]; then \
	    printf '用法: make upstream-patch-regen PRISTINE=<干净原版源码目录>\n'; \
	    printf '  例如: tar -xJf 7z2603-src.tar.xz -C /tmp/z7pristine && \\\n'; \
	    printf '        make upstream-patch-regen PRISTINE=/tmp/z7pristine\n'; \
	    exit 2; \
	fi
	sh '$(ROOT)/dist/build/regen_upstream_patch.sh' '$(PRISTINE)' '$(SRC)'

# ---------------------------------------------------------------------------
# clean / distclean
# ---------------------------------------------------------------------------
clean:
	rm -rf '$(BUILD)/7zz' '$(BUILD)/.installer' '$(BUILD)/.selfcheck' \
	       '$(DIST)/app-src/.build' '$(DIST)/ql-src/.build' \
	       '$(DIST)/engine/.build' '$(DIST)/tests/.build' \
	       '$(DIST)/lib' \
	       '$(DIST)/pack' '$(DIST)/payload' '$(DIST)/dmg-src' '$(DIST)/tar-src' \
	       '$(APP)'
	rm -f '$(DIST)'/*.pkg '$(DIST)'/*.dmg '$(DIST)'/*.tar.xz '$(DIST)'/*.tar.gz \
	      '$(DIST)'/*.tar.gz.sha256 '$(DIST)/engine'/.build_*.log \
	      '$(DIST)/tests/engine_test' '$(DIST)/tests/objc_test'
	@echo '   已删除构建产物'

# Also removes the upstream compile directory. Use this whenever a rebuild
# appears to be ignored.
distclean: clean
	rm -rf '$(BUNDLE)/b'
	@echo '   已删除上游编译目录 b/'

# ---------------------------------------------------------------------------
help:
	@printf '7-Zip %s macOS port\n\n' '$(VERSION)'
	@printf '用法: make [目标]\n\n'
	@printf '  all         默认：engine → enginebin → bridge → app → pkg\n'
	@printf '  engine      编译 arm64 引擎（上游 Alone2 目标）\n'
	@printf '  enginebin   取出引擎可执行体并 ad-hoc 签名 → dist/build/7zz\n'
	@printf '  dylib       构建内嵌引擎动态库 → dist/lib/lib7z.dylib\n'
	@printf '  bridge      构建桥接层 → dist/lib/lib7zbridge*.a\n'
	@printf '  app         组装 7-Zip.app（含 Quick Look 扩展）\n'
	@printf '  ql          仅重建 Quick Look 扩展\n'
	@printf '  pkg         生成 .pkg / .dmg / .tar.xz / checksums.txt\n'
	@printf '  tarball     生成 Homebrew 分发包\n'
	@printf '  test        桥接层验收（对照官方 7zz）\n'
	@printf '  objc-test   ObjC 适配层验收\n'
	@printf '  appcheck    应用包验收（依赖解析 / 部署目标 / 签名 / 真实启动）\n'
	@printf '  verify      离线校验脚本逻辑与公式一致性\n'
	@printf '  check        verify + 产物校验和、DMG 完整性、应用签名\n'
	@printf '  upstream    升级上游引擎（下载→校验→解包→施加移植补丁）\n'
	@printf '  upstream-patch 校验上游源码是否已带移植补丁\n'
	@printf '  clean       删除构建产物\n'
	@printf '  distclean   clean + 删除上游编译目录 b/\n'
	@printf '\n变量: JOBS=%s（并行度）  DEPLOY=%s（最低系统版本）\n' '$(JOBS)' '$(DEPLOY)'
	@printf '      NEW=%s（make upstream 的目标版本，如 26.04）\n' '$(NEW)'
