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

### 坑点 3：改动源码后需强制重建

`rm -rf b/m_arm64` 之类的批量删除可能被安全策略拦截；若删除未生效，
`make` 会认为目标文件是最新的而**静默跳过重编译**。改用 `-B` 强制重建：

```bash
make -B -j8 -f ../../cmpl_mac_arm64.mak
```

### 坑点 4：zsh 变量名不能以数字开头

```bash
# ✗ 报错 no such file or directory
7ZZ=/path/to/7zz && $7ZZ

# ✓
SZ=/path/to/7zz && $SZ
```

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
└── share/doc/7zip/                    (许可证、格式规范、readme、卸载脚本)

root-app/Applications/7-Zip.app/       组件包 com.7-zip.7zip  → /Applications
├── Contents/MacOS/7-Zip               (755)
├── Contents/Resources/7zz             (755, 与应用内嵌引擎同源)
└── Contents/PlugIns/7ZipQuickLook.appex   (Quick Look 预览扩展)
```

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
| 应用签名 | `codesign --verify --deep --strict 7-Zip.app` | 通过 |
| 扩展沙箱 | `codesign -d --entitlements - .../7ZipQuickLook.appex` | 含 `com.apple.security.app-sandbox` |
| 脚本逻辑 | `sh build/verify_scripts.sh` | 全部通过 |
| 公式一致性 | `sh homebrew/verify_formula.sh` | 全部通过 |
| 包完整性 | `pkgutil --check-signature pkg` | 未签名（预期，见下） |
| DMG 完整 | `hdiutil verify x.dmg` | checksum VALID |
| 功能往返 | `7zz a -mx=9` → `t` → `x` → `diff` | 逐字节一致 |

> `installer` 与 `pkgbuild`（无 root 时）无法在本机直接完整演练安装流程：
> `installer` 强制要求 root。因此 `verify_scripts.sh` 采用「解包真实负载 →
> 在临时前缀上重放安装/卸载逻辑」的方式验证脚本，无需提权。

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
