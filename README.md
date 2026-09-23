# 7-Zip 26.03 · macOS 原生移植

[![平台](https://img.shields.io/badge/macOS-11.0%2B-lightgrey)](#八已知限制)
[![架构](https://img.shields.io/badge/arch-arm64-green)](#八已知限制)
[![上游](https://img.shields.io/badge/7--Zip-26.03-orange)](https://www.7-zip.org/)
[![许可证](https://img.shields.io/badge/license-LGPL--2.1--orlater-blue)](./LICENSE)

> **English** — A macOS-native port of 7-Zip 26.03. Apple Silicon binaries
> (arm64 only) built from the official upstream source, plus an AppKit GUI,
> a Quick Look preview extension, Finder services, shell completions, man pages
> and a Homebrew formula. Licensed LGPL-2.1-or-later with the unRAR restriction.

上游 7-Zip 只发布 Windows 版本；macOS 用户长期依赖 `p7zip`
（2016 年后停止更新，且不含 7-Zip 26 的容器与编解码器）。本项目把 26.03 的
完整源码在 macOS 上原生构建，并补齐 macOS 系统集成，使 `7zz` 成为
`brew` 之外真正可用的命令行归档工具。

**压缩核心零改动**：所有压缩、解压、加密与校验逻辑均直接用上游源码编译，
移植层只新增 macOS 外壳与系统集成，未修改任何算法实现。

---

## 一、功能矩阵

| 组件 | 内容 | 安装位置 |
|---|---|---|
| **命令行引擎** | `7zz`（arm64，仅 Apple Silicon），含 7z / XZ / BZip2 / GZip / TAR / ZIP / WIM / RAR 解压等全部上游能力，AES-256 加密，多线程 | `/usr/local/bin/7zz` |
| **命令别名** | `7z` → `7zz` 符号链接 | `/usr/local/bin/7z` |
| **手册页** | `man 7zz`（完整命令与开关说明）、`man 7z`（别名页） | `/usr/local/share/man/man1/` |
| **命令补全** | zsh / bash / fish 三套，按子命令区分可用开关 | `/usr/local/share/{zsh,bash-completion,fish}/` |
| **图形界面** | 原生 AppKit 应用，**引擎内嵌于进程**（`Contents/Frameworks/lib7z.dylib`，不派生 `7zz` 子进程）：拖放、归档树浏览（八列、排序、搜索、右键菜单、拖出、空格预览）、压缩、追加与**删除条目**、解压、完整性校验，以及完整的压缩参数面板（格式/等级/方法/字典/字长/快速字节/匹配查找器/固实与分块/线程/分卷/加密算法/文件名加密/压缩头/完整路径） | `/Applications/7-Zip.app` |
| **Quick Look** | 按空格即预览归档内容，不再显示十六进制乱码 | `7-Zip.app/Contents/PlugIns/7ZipQuickLook.appex` |
| **Finder 服务** | 右键「服务」中的**用 7-Zip 压缩** / **用 7-Zip 解压** | 随应用注册 |
| **文档类型** | 向 LaunchServices 声明 `.7z`、`.zip`、`.tar`、`.gz`、`.bz2`、`.xz`、`.zst`、`.rar`、`.cab`、`.iso` 等 | 随应用注册 |

### 命令行补全示例

```bash
7zz a -<Tab>        # 压缩：给出 -mx、-mhe、-sdel 等写入类开关
7zz l -<Tab>        # 列表：给出 -aoa、-p 等读取类开关（不会误给写入类开关）
7zz l -t <Tab>      # 补全容器类型：7z、zip、tar、gzip、xz、bzip2、zstd …
```

### 界面设计

图形界面按 macOS 人机界面指南实现，不使用自绘窗口装饰：

| 区域 | 实现 |
|---|---|
| 标题栏 | 统一工具栏（`NSWindowToolbarStyleUnified`）：窗口标题与按钮同处一行；打开归档后标题下方显示归档名，可 ⌘-点击在 Finder 中定位 |
| 工具栏 | 纯图标按钮（SF Symbols，`NSToolbarDisplayModeIconOnly`），悬停显示中文说明；系统符号缺失时自动降级为文字按钮，不会出现空白按钮；搜索框使用系统 `NSSearchToolbarItem` |
| 压缩参数 | 收进工具栏「压缩选项」弹出的 `NSPopover`，不占用主界面；面板内两列对齐排布 |
| 内容区 | 有归档时是八列表格（`NSTableViewStyleFullWidth`），没有时是居中的空状态（图标 + 标题 + 说明 + 主操作按钮），二者互斥显示，不叠加 |
| 日志 | 默认收起，出错或出现告警时自动展开；也可由工具栏按钮或 ⌘L 开关 |
| 状态栏 | 底部通栏，左侧为当前状态（就绪 / 已载入 N 项 / 进度），右侧为当前压缩参数摘要 |
| 外观 | 全部使用语义色（`labelColor`、`secondaryLabelColor`、`windowBackgroundColor`、`controlAccentColor`、`textBackgroundColor`），浅色与深色外观下自动适配 |

> 内容区（表格与空状态）与日志抽屉的 frame 由代码直接计算而非 Auto Layout
> 约束——这是实测踩坑后的约定（`NSScrollView` 由约束定位时会被 AppKit 跳过
> 绘制），原因与完整排查记录见 `BUILD.md` 坑点 7。

---

## 二、目录结构

```
.
├── 7z2603-src/                上游 7-Zip 26.03 源码（原样内置，含 DOC/ 许可文件）
├── dist/                      移植层：源码、构建脚本与产物输出目录
│   ├── app-src/               AppKit 应用源码（main.m、Info.plist、build_app.sh）
│   ├── engine/                引擎内嵌层
│   │   ├── build_dylib.sh     由上游 Format7zF Bundle 构建 lib7z.dylib
│   │   ├── SevenZipEngine.{h,cpp}      C++ 桥接层（归档读写、安全策略、任务取消）
│   │   ├── SevenZipEngineObjC.{h,mm}   Objective-C 适配层（App 实际调用的一层）
│   │   └── build_engine.sh    构建 lib7zbridge.a + lib7zbridgeobjc.a
│   ├── tests/                 验收测试与工具
│   │   ├── engine_test.cpp    桥接层验收程序（对照官方 7zz 逐项比对）
│   │   ├── objc_test.m        ObjC 适配层验收程序
│   │   ├── verify_engine.sh   桥接层验收套件（85 个用例）
│   │   ├── verify_app.sh      应用包验收（依赖解析 / 部署目标 / 签名 / 真实启动）
│   │   └── build_test.sh, build_objc_test.sh
│   ├── lib/                   构建产物：lib7z.dylib、lib7zbridge*.a
│   ├── ql-src/                Quick Look 扩展源码
│   │   ├── SevenZipPreviewProvider.m   预览提供者（Objective-C）
│   │   ├── ArchiveReader.c/.h          纯 C 归档解析器（进程内，不派生子进程）
│   │   └── build_ql.sh
│   ├── app-res/               应用图标（.iconset 源 + 生成的 .icns）
│   ├── build/                 打包脚本、手册页、说明文档、卸载脚本
│   │   ├── make_installer.sh  生成 .pkg / .dmg / .tar.xz 与校验和
│   │   ├── package.sh         生成 Homebrew 用的分发包
│   │   ├── mk_tarball.py      可复现归档器（固定顺序/mtime/属主/权限）
│   │   ├── verify_scripts.sh  离线验证安装/卸载脚本逻辑
│   │   ├── BUILD.md           可复现构建说明（含实测坑点）
│   │   └── uninstall.sh
│   ├── shell/                 zsh / bash / fish 补全脚本
│   ├── homebrew/              Homebrew 公式及其离线校验脚本
│   ├── resources/             安装器欢迎页、自述页
│   ├── distribution.xml       安装器分发描述（两个可选组件）
│   └── checksums.txt          当前发布产物的 SHA-256
├── docs/                      源码分析报告
├── Makefile                   构建入口
├── LICENSE                    GNU LGPL v2.1 全文
├── NOTICE                     复合许可声明（LGPL + BSD + unRAR 限制）
└── THIRD_PARTY.md             逐组件第三方归属与许可对照表
```

`dist/` 中除源码与脚本外的内容均为构建产物，已在 `.gitignore` 中排除。

---

## 三、安装

### 3.1 安装包（推荐）

从 [Releases](https://github.com/XINKEJU/7-Zip-macOS/releases) 下载
`7-Zip-26.03-macOS.dmg`，挂载后双击其中的 `.pkg`。安装器提供两个可独立勾选的
组件：命令行工具与应用。

> 当前产物为 **ad-hoc 签名**，安装包本身**未经 Apple 公证**。首次打开时若被
> Gatekeeper 拦截，请右键 `.pkg` → **打开**，或在「系统设置 → 隐私与安全性」
> 中允许。如需正式分发，请参见 `dist/build/BUILD.md` 第七节完成
> Developer ID 签名与公证。

### 3.2 免安装命令行包

```bash
curl -LO https://github.com/XINKEJU/7-Zip-macOS/releases/download/v26.03/7-Zip-26.03-macOS-arm64.tar.xz
sudo tar -xJf 7-Zip-26.03-macOS-arm64.tar.xz -C /usr/local
```

### 3.3 Homebrew

公式位于 `dist/homebrew/sevenzip-macos.rb`。它消费的是 3.2 之外的
`7zip-macos-*-arm64.tar.gz` 分发包（由 `make tarball` 生成）：

```bash
brew install --formula https://raw.githubusercontent.com/XINKEJU/7-Zip-macOS/main/dist/homebrew/sevenzip-macos.rb
```

公式名刻意取作 `sevenzip-macos` 而非 `7zip-macos`：Homebrew 会把公式文件名
转换为 Ruby 类名，`7zip-macos` → `7zipMacos` 以数字开头，不是合法常量。

### 3.4 安装了什么

```
/usr/local/bin/7zz                          命令行引擎（arm64）
/usr/local/bin/7z                           符号链接 → 7zz
/usr/local/share/man/man1/7zz.1             手册页
/usr/local/share/man/man1/7z.1              别名手册页
/usr/local/share/zsh/site-functions/_7zz    zsh 补全
/usr/local/share/bash-completion/completions/7zz
/usr/local/share/fish/vendor_completions.d/7zz.fish
/usr/local/share/doc/7zip/                  许可证、格式规范、说明、归属声明、卸载脚本
/Applications/7-Zip.app                     图形应用
/Applications/7-Zip.app/Contents/PlugIns/7ZipQuickLook.appex
```

---

## 四、从源码构建

### 4.1 依赖

| 组件 | 要求 |
|---|---|
| 系统 | macOS 11.0 及以上（Quick Look 扩展需 12.0） |
| 工具链 | Xcode Command Line Tools（Apple clang）、GNU make |
| 打包 | `pkgbuild` / `productbuild` / `hdiutil` / `lipo` / `codesign`（随系统提供） |

### 4.2 一条命令

```bash
make            # engine → enginebin → app → pkg
```

产物写入 `dist/`：

| 文件 | 说明 |
|---|---|
| `7-Zip-26.03-macOS.pkg` | 集成安装包（命令行 + 应用，可勾选） |
| `7-Zip-26.03-macOS.dmg` | 磁盘映像（含安装包、README、卸载脚本） |
| `7-Zip-26.03-macOS-arm64.tar.xz` | 仅命令行的免安装包 |
| `7zip-macos-26.03-macos-arm64.tar.gz` | Homebrew 分发包（`make tarball`） |
| `checksums.txt` | 上述产物的 SHA-256 |

### 4.3 分步

```bash
make engine      # 编译 arm64 引擎（上游 Alone2 目标）
make enginebin   # 取出可执行体 + ad-hoc 签名 → dist/build/7zz
make dylib       # 构建内嵌引擎动态库 → dist/lib/lib7z.dylib
make bridge      # 构建桥接层 → dist/lib/lib7zbridge*.a
make app         # 组装 7-Zip.app，并构建内嵌 Quick Look 扩展
make ql          # 只重建 Quick Look 扩展
make pkg         # 生成 .pkg / .dmg / .tar.xz / checksums.txt
make tarball     # 生成 Homebrew 分发包
make test        # 桥接层验收（对照官方 7zz 逐项比对，85 个用例）
make objc-test   # ObjC 适配层验收（App 实际调用的那一层，41 个用例）
make appcheck    # 应用包验收：依赖解析 / 部署目标 / 签名 / 真实启动（21 个用例）
make verify      # 离线校验：安装/卸载脚本逻辑 + 公式一致性
make check       # verify + 产物校验和、DMG 完整性、应用签名
make clean       # 删除构建产物
make distclean   # 连同上游 b/ 编译目录一并删除
```

> `make appcheck` 会**真实启动一次应用**并确认：进程内已映射
> `Contents/Frameworks/lib7z.dylib`、且**没有派生任何 `7zz` 子进程**。
> 它同时会把每个 `@rpath` 依赖真正解析成磁盘路径——这条检查能挡住
> "库是对的但应用起不来"（如 `install_name` 与文件名不一致）这类只在运行期
> 暴露的问题。

工程细节与实测坑点（macOS 专用 makefile、`MACOSX_DEPLOYMENT_TARGET`、
扩展签名顺序、扩展属性与 `._` 条目等）记录在
[`dist/build/BUILD.md`](dist/build/BUILD.md)，建议构建前先读。

---

## 五、卸载

```bash
sudo sh /usr/local/share/doc/7zip/uninstall.sh
```

脚本逐个删除本包安装的文件：`7zz`、`7z` 符号链接（核对确实指向 `7zz` 后才删）、
两页手册、三套补全、文档目录、`/Applications/7-Zip.app` 及其 Quick Look 扩展，
最后 `pkgutil --forget` 清理两个收据。

安全约束已内建并有测试覆盖（`make verify`）：共享的补全目录只删本包拥有的那
一项；文档目录逐文件删除后仅在其为空时 `rmdir`。用户自行放入的内容不会被误删。

---

## 六、Quick Look 扩展的实现要点

macOS 26 起，旧式 `.qlgenerator` 插件已不再被 `quicklookd` 加载，只支持
**应用扩展**（`.appex`）。本扩展据此实现，并有两个非显而易见的设计约束：

1. **扩展必须编译为 `MH_EXECUTE` 而非 `MH_BUNDLE`。** 以 `-bundle` 链接时，
   ad-hoc 签名会静默丢弃 `com.apple.security.app-sandbox` 权限，ExtensionKit
   随即拒绝注册。构建脚本因此显式使用 `-Wl,-e,_NSExtensionMain`。
2. **ad-hoc 签名下扩展不能派生子进程。** 调用内嵌 `7zz` 需要
   `com.apple.security.inherit`，而该权限只在具备真实团队身份的签名下生效；
   `posix_spawn` 会以 `EPERM` 失败。扩展因此改为**在进程内**用纯 C 解析归档
   （`ArchiveReader.c`），完全不依赖外部进程。

据此得到的预览能力：

| 类型 | 行为 |
|---|---|
| ZIP / ZIP64、TAR（ustar、GNU 长名、pax）、GZIP | 完整文件列表：名称、原始大小、压缩后大小、修改时间、属性；含总文件数/文件夹数 |
| 7z、XZ、BZip2、Zstd、RAR、CAB、ISO 9660、DMG | 容器识别与元信息（如 7z 容器版本与头大小），并提示需用命令行列出完整内容 |
| 截断或损坏 | 明确报错（例如「ZIP 结束记录（EOCD）缺失」），不静默失败 |

若以 Developer ID 正式签名并授予 `com.apple.security.inherit`，扩展会优先调用
内嵌 `7zz`，从而对**所有**格式给出完整列表；这条路径已在代码中实现并保留。

---

## 七、验证

`make verify` 覆盖无需提权即可执行的全部检查：

- **脚本逻辑**：解包真实安装载荷，在临时前缀上重放安装与卸载流程，断言
  16 项包内文件全部被删除、6 项无关文件（相邻补全、其他应用等）全部保留。
- **公式一致性**：核对 sha256 / version / url 三者匹配，复现 `install` 段的
  文件映射，并复现 `test do` 的全部断言。

安装包与 DMG 另可独立校验：

```bash
shasum -a 256 -c dist/checksums.txt
hdiutil verify dist/7-Zip-26.03-macOS.dmg
pkgutil --expand-full dist/7-Zip-26.03-macOS.pkg /tmp/exp    # 检查载荷与签名
```

> `installer` 命令强制要求 root，因此无法在无提权环境中演练完整安装。
> 上面的载荷解包校验是等价替代。

---

## 八、已知限制

1. **未签名、未公证。** 产物为 ad-hoc 签名，其他用户首次安装需右键打开。
   正式分发须自备 Apple Developer ID，步骤见 `BUILD.md`。
2. **Quick Look 的 7z 完整列表**需要正式签名（见第六节）；当前对 7z 给出容器
   概要而非文件清单。ZIP / TAR / GZIP 不受影响，均为完整列表。
3. **只支持 Apple Silicon。** 2026-09-24 起不再构建 x86_64 切片——它占每个
   可执行体体积的近一半，而 Intel Mac 已无在售机型。Intel 机器会直接报
   「bad CPU type in executable」（Rosetta 2 是把 x86_64 翻译成 arm64，方向相反，
   帮不上忙）。上游源码未改，恢复 x86_64 只需把各构建脚本里的分支加回来。
4. **最低系统版本 11.0**（首个支持 Apple Silicon 的版本）；应用扩展为 12.0。
5. **不提供 32 位支持。**

---

## 九、许可证

本项目是上游 7-Zip 的**衍生作品**，整体适用与上游相同的条款：

- **GNU LGPL v2.1 或更高版本** —— 全文见 [`LICENSE`](LICENSE)
- **unRAR 许可证限制** —— 二进制编入了 RAR 解压引擎，因此随附该限制文本；
  可解压 RAR，但**不得**用于开发 RAR 兼容压缩器
- 源码中个别文件适用 BSD 2/3-clause（LZFSE、Zstandard、XXH64 解码）

完整声明见 [`NOTICE`](NOTICE)、[`THIRD_PARTY.md`](THIRD_PARTY.md)（逐组件归属与
许可对照表，随安装包、应用包与 Homebrew 分发包一同分发）与上游原文件
`7z2603-src/DOC/{License,copying,unRarLicense}.txt`。

```
7-Zip Copyright (C) 1999-2026 Igor Pavlov.
macOS port Copyright (C) 2026 XINKEJU and contributors.
```

「7-Zip」「RAR」「WinRAR」为其各自所有者的商标。本项目为独立的社区移植，与
Igor Pavlov 及 RARLAB 无隶属或背书关系。

---

## 十、致谢

- **Igor Pavlov** —— 7-Zip 及其全部压缩算法实现
- **Alexander Roshal** —— unRAR 解压代码
- **Apple / Facebook / Yann Collet** —— LZFSE、Zstandard、XXH64 解码实现
