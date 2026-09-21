# 7-Zip 26.03 macOS 通用二进制与安装包 — 可复现构建说明

本文档记录从官方源码到 macOS 安装包的完整构建流程，含实测发现的坑点。
所有命令均在 Apple Silicon + macOS 26.1 SDK + Apple clang 17.0.0 环境实测通过。

---

## 一、前置条件

| 组件 | 要求 | 本机实测值 |
|---|---|---|
| 源码 | 7-Zip 26.03 已解压 | `7z2603-src/` |
| 编译器 | Apple clang（Xcode CLT） | 17.0.0 |
| make | GNU Make | 3.81（macOS 自带） |
| 打包工具 | `pkgbuild` / `productbuild` / `hdiutil` / `lipo` / `codesign` | 均可用 |

源码获取（若尚未下载）：

```bash
curl -fL -O https://github.com/ip7z/7zip/releases/download/26.03/7z2603-src.tar.xz
tar -xJf 7z2603-src.tar.xz
```

---

## 二、关键坑点（务必先读）

### 坑点 1：必须使用 macOS 专用 makefile

```bash
# ✗ 错误 —— 会失败
make -f ../../cmpl_clang.mak
# fatal error: include location '/usr/local/include' is unsafe for
# cross-compilation [-Wpoison-system-directories]

# ✓ 正确
make -f ../../cmpl_mac_arm64.mak      # arm64
make -f ../../cmpl_mac_x64.mak        # x86_64
```

原因：`cmpl_clang.mak` 引用 `warn_clang.mak`，其中缺少 `-Wno-poison-system-directories`。
macOS 专用入口 `cmpl_mac_arm64.mak` / `cmpl_mac_x64.mak` 引用的是 `warn_clang_mac.mak`，已包含该豁免。

### 坑点 2：默认部署目标会被抬到当前 SDK 版本

不显式指定时，二进制的最低系统版本 = 构建机的 SDK 版本（本机为 **macOS 26.1**），
导致在老系统上无法启动。必须导出环境变量：

```bash
export MACOSX_DEPLOYMENT_TARGET=11.0
```

macOS 11.0 是首个支持 Apple Silicon 的版本，作为下限最稳妥。
验证方式：

```bash
otool -arch arm64 -l 7zz | grep -A4 LC_BUILD_VERSION | grep minos
# 期望输出：minos 11.0
```

**上游的 `CPP/7zip/var_mac_*.mak` 只设置 `-arch`，不含最低系统版本**，因此
内嵌引擎库 `lib7z.dylib` 同样会继承 SDK 默认值。`build_dylib.sh` 已导出该变量，
但如果手工编译 dylib，务必自己加上，否则会产出 minos=26.1 的库——它在
macOS < 26.1 上会被 dyld **直接拒绝加载**，而 `7zz` 却是 11.0，两边不一致极难察觉。

### 坑点 3：改动源码后需强制重建

`rm -rf b/m_arm64` 之类的批量删除可能被安全策略拦截；若删除未生效，
`make` 会认为目标文件是最新的而**静默跳过重编译**。改用 `-B` 强制重建：

```bash
make -B -j8 -f ../../cmpl_mac_arm64.mak
```

同一现象也会伪装成"脚本改了但产物没变"：`build_engine.sh` / `build_dylib.sh`
原先都先 `rm -f` 再重建，删除被拦截后脚本**提前中止**，旧产物原地不动。
现在两个脚本都不再依赖删除（`lipo` 直接覆盖、`ar` 写临时文件再 `mv`），
从根上避免这个陷阱。

### 坑点 4：dylib 的 install_name 必须与文件名一致

dyld 按 `@rpath/<install_name 的末段>` 查找依赖。若 `install_name` 写成
`@rpath/7z.dylib` 而文件名为 `lib7z.dylib`，会出现：

```
dyld: Library not loaded: @rpath/7z.dylib
  Reason: tried: '.../Contents/Frameworks/7z.dylib' (no such file)
```

`otool -L` 只能证明"引用了某个 rpath 依赖"，**不能证明该依赖能被解析**——
这条命令曾经是通过的，而应用一启动就崩。因此 `build_app.sh` 与
`verify_app.sh` 都会把每个 `@rpath`/`@executable_path` 依赖**真正解析成磁盘
路径并断言文件存在**，同时校验 install_name 末段与文件名一致。

### 坑点 5：zsh 变量名不能以数字开头

```bash
# ✗ 报错 no such file or directory
7ZZ=/path/to/7zz && $7ZZ

# ✓
SZ=/path/to/7zz && $SZ
```

### 坑点 6：C 关键字不能用作局部变量名

`short`、`long`、`signed` 等在 Objective-C 里仍是关键字，
`NSString *short = ...` 会报 `expected identifier or '('`。

### 坑点 7：`NSScrollView` 不能用 Auto Layout 摆放

`dist/app-src/main.m` 里，**表格（`outlineScroll`）、空状态（`emptyState`）与日志
抽屉（`logScroll`）的 frame 一律由 `layoutContentFrames`（经 `viewDidLayout`
调用）直接赋值，刻意不参与 Auto Layout**。这不是风格选择，而是踩过坑之后的
结果：在本机（macOS 26 / AppKit，1470×923@2x 逻辑分辨率）把这些视图交给约束
管理时，出现过这样的现象——

- 视图的 `frame`、`bounds`、`hidden`、`alpha`、父视图与窗口层级全部正确；
- `hasAmbiguousLayout` 全为 `NO`，控制台没有任何约束冲突日志；
- 但**该视图连同它内部整棵子树都不出现在屏幕上**，`screencapture` 与
  `cacheDisplayInRect:` 的结果一致，说明不是截屏假象。

逐一排除过的变量（均无法解释或无法修复）：尺寸是否推导得出、是否布局歧义、
是否有隐藏祖先、是否顶边锚定、`NSWindowToolbarStyle` 取 Unified 还是 Expanded、
有无 `drawRect:` 实现、是否 `wantsLayer` / layer 承载。**对照组**：同一父视图下
显式设定 frame 的视图（`autoresizingMask`）、以及按约束摆放但带显式高度的
底部状态栏（`Z7BarView`，自定义不透明视图）与分隔线，都始终正常显示。

**日志抽屉的补充结论（第二轮修复）**：抽屉最初是照「底部三件套用 Auto Layout」
的约定写的——约束解算完全正确（实测 `logScroll` 得到 `0,31,1040,132`，文本视图
内含 215 字符），界面上的那 132pt 却是一片空白，用它换来的唯一可见效果是内容
区中心上移了 164pt。改成显式 frame 后立刻正常绘制。可见触发条件与「是不是
内容区」无关，而与**视图类型是 `NSScrollView`** 有关：凡 `NSScrollView` 作为
`drop` 的直接子视图由约束定位，就会被跳过绘制。

因此约定：**所有 `NSScrollView`（内容区表格、日志抽屉）用显式 frame；只有
自定义不透明的状态栏与分隔线保留 Auto Layout。** 由此带来两个必须同时保留的
配套处理：

1. 自下而上一次性分配矩形：状态栏 30 → 分隔线 1 →（展开时）日志抽屉 132 +
   分隔线 1 → 内容区（表格与空状态共用这块矩形、互斥显示，frame 始终一致）。
   全部集中在 `layoutContentFrames` 一个方法内，`viewDidLayout` 与
   `setLogVisible:` 都调它，切换抽屉时不必等下一次布局循环；
2. 内容区不再参与约束后窗口的内容自适应尺寸会变得很小（实测宽度被压到
   145pt），故 `main.m` 中为 `drop` 补了一条最小宽度约束（880），并在
   `setFrameAutosaveName:` 返回 `NO`（首次运行）时显式给回 1040×700。

若日后要改回约束布局，请先把上面 7 项变量逐一对齐到「能显示」的那一组，并
用 `screencapture` 实测，不要只凭 `frame` 数值判断正确性——**布局数值正确与
内容被绘制是两件事**。

## 二·补：内嵌引擎库的构建顺序

应用依赖三个产物，顺序固定：

```bash
sh dist/engine/build_dylib.sh     # 1. lib7z.dylib（Format7zF Bundle）
sh dist/engine/build_engine.sh    # 2. lib7zbridge.a + lib7zbridgeobjc.a
sh dist/app-src/build_app.sh ...  # 3. 组装 7-Zip.app
```

或直接用 `make`（已编码该依赖关系）：

```bash
make dylib      # 仅引擎库
make bridge     # 引擎库 + 桥接层
make app        # 全部 + 应用包
make appcheck   # 应用包验收（依赖解析 / 部署目标 / 签名 / 真实启动）
```

`build_app.sh` 会把 `lib7z.dylib` 放进 `Contents/Frameworks/`，并把主程序的
`LC_RPATH` 设为 `@executable_path/../Frameworks`。

---

## 三、构建两个切片

```bash
cd 7z2603-src/CPP/7zip/Bundles/Alone2
export MACOSX_DEPLOYMENT_TARGET=11.0

make -B -j8 -f ../../cmpl_mac_arm64.mak     # → b/m_arm64/7zz
make -B -j8 -f ../../cmpl_mac_x64.mak       # → b/m_x64/7zz
```

说明：
- 编译告警等级为 `-Wall -Wextra -Weverything -Werror -Wfatal-errors`，源码零告警通过。
- arm64 目标含手写汇编（`Asm/arm64/LzmaDecOpt.S`），x86_64 目标 `USE_ASM=` 为空（不依赖外部汇编器）。
- 若想为 x86_64 启用汇编优化，需安装 Asmc / UASM 并改用 `cmpl_gcc_x64.mak`。

## 四、合并为通用二进制

```bash
cd dist && mkdir -p build
lipo -create <src>/b/m_arm64/7zz <src>/b/m_x64/7zz -output build/7zz
codesign --force --sign - --timestamp=none build/7zz

lipo -archs build/7zz          # → x86_64 arm64
codesign --verify --strict build/7zz
```

`lipo` 合并后原签名失效，必须重新 ad-hoc 签名，否则 arm64 切片可能被内核拒绝执行。

---

## 五、组装负载与打包

集成安装包由 `build/make_installer.sh` 一次产出。它搭建两棵负载树，分别打成
组件包，再由 `productbuild` 合成带选择界面的分发安装包：

```
root-cli/usr/local/                    组件包 com.7-zip.7zz   → /usr/local
├── bin/7zz                            (755, 通用二进制)
├── bin/7z -> 7zz                      (符号链接)
├── share/man/man1/7zz.1               (644)
├── share/man/man1/7z.1                (644)
├── share/zsh/site-functions/_7zz      (644)
├── share/bash-completion/completions/7zz
├── share/fish/vendor_completions.d/7zz.fish
└── share/doc/7zip/                    (许可证、格式规范、readme、卸载脚本、THIRD_PARTY.md)

root-app/Applications/7-Zip.app/       组件包 com.7-zip.7zip  → /Applications
├── Contents/MacOS/7-Zip               (755, 前端；链接桥接层)
├── Contents/Frameworks/lib7z.dylib    (755, 内嵌引擎；LGPL 可替换库)
├── Contents/Resources/THIRD_PARTY.md  (第三方归属与许可)
└── Contents/PlugIns/7ZipQuickLook.appex   (Quick Look 预览扩展)
    └── Contents/Resources/7zz         (755, 沙盒扩展自带的 helper；带 inherit 权限)

> **为什么内嵌 `lib7z.dylib`、而 `7zz` 只出现在 Quick Look 扩展里？**
> 前端自身的归档操作全部通过 `lib7z.dylib` 在**进程内**完成（技术方案 §1.3），
> 不再派生 `7zz`。Quick Look 扩展运行在 App Sandbox 中，无法加载应用包的
> 动态库，因此由 `ql-src/build_ql.sh` 把**自己的一份** `7zz` 放进 appex 并配以
> `7zz-helper.entitlements`（含 `com.apple.security.inherit`）再签名；
> `SevenZipFindTool()` 的候选列表只解析到 appex 自身（见 `ql-src/SevenZipPreviewProvider.m`），
> 从不指向宿主应用。因此宿主应用包**不再**携带 `7zz`——审计（2026-09-22）确认
> 那份 6.01 MB 的副本从不参与运行，属纯死载荷，移除后预览能力不受影响。
> 若日后要在应用内也派生 `7zz`，必须连同 helper 权限一起重新评估，不能简单复制。

```bash
# 一条命令完成全部打包
sh build/make_installer.sh
```

脚本内部等价于：

```bash
# 1) 两个组件包
pkgbuild --root root-cli --identifier com.7-zip.7zz \
         --version 26.03 --install-location / --ownership recommended \
         --scripts scripts-cli 7-Zip-cli.pkg
pkgbuild --root root-app --identifier com.7-zip.7zip \
         --version 26.03 --install-location / --ownership recommended \
         --scripts scripts-app 7-Zip-app.pkg

# 2) 分发安装包（欢迎页 / 自述 / 许可证 + 两个可选组件）
productbuild --distribution distribution.xml \
             --resources resources \
             --package-path pkgs \
             7-Zip-26.03-macOS.pkg

# 3) DMG（内含 .pkg + README-macos.txt + uninstall.sh）
hdiutil create -volname "7-Zip 26.03" -srcfolder dmg \
               -fs HFS+ -format UDZO -ov 7-Zip-26.03-macOS.dmg

# 4) 免安装归档（仅命令行工具）
tar -cJf 7-Zip-26.03-macOS-universal.tar.xz -C root-cli/usr/local .
```

### 关于扩展属性与 `._` 条目

`pkgbuild` 会为非 root 构建打印若干条 `write: Permission denied`。这是
**非致命且与本项目无关**的：macOS 会给每个新建文件附加受保护的
`com.apple.provenance` 扩展属性，普通用户无权重写它，`pkgbuild` 于是退化为
把扩展属性以 AppleDouble 形式写进负载，BOM 中因此出现在 `._name` 条目。
系统安装器会在落盘时把它还原为扩展属性并删除 sidecar，不会留下垃圾文件
（已用 `co.effie.ios.bom` 及本机既有安装实证）。以 root 运行 `pkgbuild` 时
该告警消失。

实测补充（26.03 起）：

| 结论 | 验证方式 |
|---|---|
| 该属性**由内核在文件创建时自动附加**，无法规避 | `cp -X`、`ditto --noextattr` 产出的副本同样带上它 |
| 在受沙箱约束的环境里**无法移除** | `xattr -d com.apple.provenance` 返回 0 但属性仍在；`xattr -cr` 亦然 |
| 载荷中的 `._` 条目**不会落成实体文件** | 解包 `Payload` 后 `find -name '._*'` 计数为 0（libarchive 将其合并回属性） |

因此三个构建脚本都在**签名之前**执行 `xattr -cr`（`build_app.sh`、
`build_ql.sh`、`make_installer.sh`）：在正常终端里这会把载荷清干净；在无法
移除属性的环境里它退化为无操作，`make_installer.sh` 会如实报告受影响条目
数，由第 10 节的产物自检断言"解包后无 `._*` 实体文件"。

> **顺序不可颠倒。** 代码签名会把扩展属性纳入封存，签名之后再清除属性等于
> 破坏签名。这正是 `make_installer.sh` 第 10 节要额外做一次
> `codesign --verify` 的原因：它专抓"清属性与签名顺序写反"这类错误。

### 关于可复现归档

Homebrew 公式里钉住的是分发包的 sha256，`homebrew/verify_formula.sh` 会断言
该值等于磁盘上分发包的实际哈希。若用 `/usr/bin/tar` 打包，这个断言**每次
重建都会失败**，原因有两条且相互独立：

1. tar 记录每个条目的 mtime，而 `install` 会把 mtime 设为"此刻"；
2. tar 按 readdir 顺序输出条目，该顺序在不同文件系统之间甚至同一文件系统的
   不同次运行之间都不保证一致。

macOS 自带的是 bsdtar 3.5.3，GNU tar 的 `--sort=name` 与 `--mtime` **都不
支持**，因此常见的 `tar --sort=name --mtime=...` 配方在这里用不了。归档改由
`build/mk_tarball.py` 完成：显式按名称字节序排序、mtime 固定（默认
`2025-01-01T00:00:00Z`，可用 `SOURCE_DATE_EPOCH` 覆盖）、uid/gid 归零、
uname/gname 清空、权限归一化为 0755/0644、gzip 头 mtime 置 0。

结果是归档只取决于文件名集合与文件内容：**只要二进制没变，sha256 就不变**，
公式里的值因此是可复算的，而不是每次构建都要手工打补丁的。

```bash
# 连续两次打包应得到同一个哈希
sh dist/build/package.sh && shasum -a 256 dist/7zip-macos-26.03-macos-universal.tar.gz
sh dist/build/package.sh && shasum -a 256 dist/7zip-macos-26.03-macos-universal.tar.gz
```

### 关于文档目录命名

文档目录统一为 `/usr/local/share/doc/7zip`（小写、无连字符）。**不要**在其中
放置任何名为 `README.txt` 的文件：macOS 默认卷大小写不敏感，`README.txt` 与
上游 `readme.txt` 会指向同一目录项，后写入者静默覆盖前者——本移植版的说明文件
因此命名为 `README-macos.txt`。

---

## 六、验证清单

| 检查项 | 命令 | 期望 |
|---|---|---|
| 架构完整 | `lipo -archs 7zz` | `x86_64 arm64` |
| 部署目标 | `otool -arch arm64 -l 7zz \| grep -A4 LC_BUILD_VERSION` | `minos 11.0` |
| 签名有效 | `codesign --verify --strict 7zz` | 通过 |
| 动态依赖 | `otool -L 7zz` | 仅 `libSystem` / `libc++` |
| 负载路径 | `lsbom -s .../7-Zip-cli.pkg/Bom` | 含 `bin/7z` 符号链接与全部补全脚本 |
| 引擎库部署目标 | `otool -l Contents/Frameworks/lib7z.dylib \| grep -A4 LC_BUILD_VERSION` | `minos 11.0`（不是 SDK 版本） |
| 依赖可解析 | `sh dist/tests/verify_app.sh` | 每个 `@rpath` 项都解析到实际存在的文件 |
| 引擎在进程内 | `vmmap <pid> \| grep lib7z` 且 `pgrep -P <pid>` | 已映射；**无 7zz 子进程** |
| 应用签名 | `codesign --verify --deep --strict 7-Zip.app` | 通过 |
| 扩展沙箱 | `codesign -d --entitlements - .../7ZipQuickLook.appex` | 含 `com.apple.security.app-sandbox` |
| 脚本逻辑 | `sh build/verify_scripts.sh` | 全部通过 |
| 公式一致性 | `sh homebrew/verify_formula.sh` | 全部通过 |
| 许可完整性 | `make pkg` 第 10 节产物自检 | 两类载荷均含 `THIRD_PARTY.md` |
| 载荷无垃圾 | 同上 | 解包后 `._*` 实体文件计数为 0 |
| 载荷内应用签名 | 同上 | `codesign --verify --deep --strict` 通过 |
| 分发包可复现 | 连续两次 `sh build/package.sh` | 两次 sha256 一致 |
| 包完整性 | `pkgutil --check-signature pkg` | 未签名（预期，见下） |
| DMG 完整 | `hdiutil verify x.dmg` | checksum VALID |
| 功能往返 | `7zz a -mx=9` → `t` → `x` → `diff` | 逐字节一致 |

自动化入口：

```bash
make test        # 桥接层验收，对照官方 7zz 逐项比对（85 个用例）
make objc-test   # ObjC 适配层验收（App 实际调用的那一层，41 个用例）
make appcheck    # 应用包验收（含真实启动与进程模型检查，21 个用例）
make verify      # 离线校验：安装/卸载脚本逻辑 + Homebrew 公式一致性
make check       # verify + 产物校验和 + DMG 完整性 + 应用签名
make tarball     # Homebrew 分发包（可复现，见上）
```

> `installer` 与 `pkgbuild`（无 root 时）无法在本机直接完整演练安装流程：
> `installer` 强制要求 root。因此 `verify_scripts.sh` 采用「解包真实负载 →
> 在临时前缀上重放安装/卸载逻辑」的方式验证脚本，无需提权。
>
> `make appcheck` 会**真实启动**应用一次（约 4 秒）并检查进程模型，
> 因此需要图形会话；在无窗口服务的环境（如纯 SSH）中该步骤会失败。

---

## 七、分发与签名

本流程产出的是 **ad-hoc 签名**的可执行文件与 **未签名**的安装包。

- 自用足够；其他用户双击 `.pkg` 时可能被 Gatekeeper 拦截，需右键 → 打开。
- 若要正式分发，需 Apple Developer ID：

```bash
productsign --sign "Developer ID Installer: 名称 (TEAMID)" \
            7-Zip-26.03-macOS.pkg 7-Zip-26.03-macOS-signed.pkg
xcrun notarytool submit 7-Zip-26.03-macOS-signed.pkg \
      --apple-id <id> --team-id <TEAMID> --password <app-password> --wait
xcrun stapler staple 7-Zip-26.03-macOS-signed.pkg
```

- 应用包本身也需先用 Developer ID Application 证书签名，再构建安装包，
  否则嵌套的 Quick Look 扩展无法通过 `com.apple.security.inherit` 获得团队身份，
  也就无法派生辅助进程（当前实现因此改为扩展内直接解析归档，见 README）。
- 本机仅存在 `IBOS Local Signing` 身份，与 7-Zip 无关，不应挪用签名。

---

## 八、卸载

```bash
sudo sh /usr/local/share/doc/7zip/uninstall.sh
```

脚本删除本包安装的全部内容：`7zz`、`7z` 符号链接（核对确指向 `7zz` 后才删）、
两页手册、三份 shell 补全、文档目录、`/Applications/7-Zip.app` 及其 Quick Look
扩展，最后 `pkgutil --forget` 清理两个收据。

安全约束：文档目录中的文件逐个删除后仅在其为空时 `rmdir`，共享的补全目录只删
本包拥有的那一项，因此用户自行放入的内容不会被误删。
