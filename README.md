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

**压缩核心零改动**：所有压缩、解压、加密与校验**算法**均直接用上游源码编译，
未修改任何算法实现。对上游源码的改动仅限 macOS 适配，共 **8 个文件修改 + 2 个文件新增**
（文件名编码归一化、隔离属性传播、构建接线），逐字节变更集见
`dist/build/upstream-macos.patch`；移植层其余代码全部新增在 `dist/` 下。

---

## 一、功能矩阵

| 组件 | 内容 | 安装位置 |
|---|---|---|
| **命令行引擎** | `7zz`（arm64，仅 Apple Silicon），含 7z / XZ / BZip2 / GZip / TAR / ZIP / WIM / RAR 解压等全部上游能力，AES-256 加密，多线程 | `/usr/local/bin/7zz` |
| **命令别名** | `7z` → `7zz` 符号链接 | `/usr/local/bin/7z` |
| **手册页** | `man 7zz`（完整命令与开关说明）、`man 7z`（别名页） | `/usr/local/share/man/man1/` |
| **命令补全** | zsh / bash / fish 三套，按子命令区分可用开关 | `/usr/local/share/{zsh,bash-completion,fish}/` |
| **图形界面** | 原生 AppKit 应用，**引擎内嵌于进程**（`Contents/Frameworks/lib7z.dylib`，不派生 `7zz` 子进程）：拖放、归档树浏览（八列、排序、搜索、右键菜单、拖出、空格或双击预览）、压缩、追加与**删除条目**、解压（同名文件可选覆盖 / 跳过 / 自动改名）、完整性校验、加密归档可**记住密码**（存入登录钥匙串），以及完整的压缩参数面板（格式/等级/方法/字典/字长/快速字节/匹配查找器/固实与分块/线程/分卷/加密算法/文件名加密/压缩头/完整路径） | `/Applications/7-Zip.app` |
| **格式补齐** | 在**上游树外**补上游缺失的能力（新增文件全部位于 `dist/engine/`，不修改上游编解码实现）：**zstd / lz4 / brotli / lzip / snappy 五种格式全部可创建 + 解压**（上游只有 zstd 解码器，lz4 / brotli / lzip / snappy 完全没有）、**ISO 与 DMG 创建**（上游两者都只能读）。详见下文「扩展格式」与第七节验证 | 随应用（**不在 `7zz` 命令行**内，见下） |
| **Quick Look** | 按空格即预览归档内容，不再显示十六进制乱码 | `7-Zip.app/Contents/PlugIns/7ZipQuickLook.appex` |
| **Finder 服务** | 在访达里选中文件或文件夹后，经菜单栏**访达 → 服务 → 文件和文件夹**使用**用 7-Zip 压缩** / **用 7-Zip 解压**。声明必须带 `NSRequiredContext`，否则系统不会把它放进菜单（失败是静默的，见 BUILD.md 坑点 33） | 随应用注册 |
| **文档类型** | 向 LaunchServices 声明 `.7z`、`.zip`、`.tar`、`.gz`、`.bz2`、`.xz`、`.zst`、`.lz`、`.lz4`、`.br`、`.sz`、`.rar`、`.cab`、`.iso` 等 | 随应用注册 |

> **`7zz` 命令行刻意保持上游原样**：它是上游 makefile 的直接产物，不含本移植补的
> 新格式（`7zz a -tzstd` / `-tiso` 会报错退出）。这样上游升级时无需改一行 makefile。
> 新格式只在应用（与 `lib7zbridge.a` 引擎接口）中提供。

### 扩展格式（本移植新增）

上游 7-Zip 26.03 有几处能力空缺。本移植在**一行上游源码都不改**的前提下补齐，
做法是把新格式做成独立于上游注册表的外部处理器（`dist/engine/Z7ExtCodec.cpp`）
与自研写入器，由引擎直接实例化：

| 格式 | 上游 26.03 | 本移植 | 做法 |
|---|---|---|---|
| zstd | 只能解压 | **可创建 + 解压** | 静态链入 `libzstd` 补上编码器 |
| lz4 | 完全不支持 | **可创建 + 解压** | 静态链入 `liblz4`（frame 格式） |
| brotli | 完全不支持 | **可创建 + 解压** | 静态链入 `libbrotli`；无魔数，仅按扩展名认领 |
| lzip | 完全不支持 | **可创建 + 解压** | 静态链入 `liblzma`，自建 lzip 容器（LZMA1 原始流 + 三因子尾） |
| snappy | 完全不支持 | **可创建 + 解压** | 自实现，无外部依赖；同时支持裸格式与分帧格式（`.sz`） |
| ISO 9660 | 只能读 | **可创建**（ISO9660 + Joliet） | 自研写入器，进程内、零依赖 |
| DMG | 只能读 | **可创建**（UDZO） | 调系统 `hdiutil`（唯一子进程例外） |

几点约定：

- **库缺失即降级**：`dist/engine/ext_codecs.sh` 探测 Homebrew 静态库，缺哪个就把
  对应格式编译出去，构建照常成功。没有装 Homebrew 的机器与 CI 都能过门禁。
  snappy 是自实现，任何构建都有。
- **单流格式一次只能压一个文件**：gz / bz2 / xz / zstd / lz4 / br / lzip / snappy
  都是单流格式，多文件压缩会被明确拒绝（与官方 `7zz` 行为一致），不会静默只压第一个。
- **静态链接**：四个库都以 `.a` 链入应用主程序，产物**不新增任何动态库依赖**，
  `.app` 与 Quick Look 扩展保持自包含。许可归属见 `THIRD_PARTY.md` 1.2 节。
- **下拉里显示格式名，文件名用惯用扩展名**：zstd → `.zst`、lzip → `.lz`、
  snappy → `.sz`。引擎按格式名归一化，两种写法都能打开。
- **仅限应用**：如上文所述，`7zz` 命令行保持上游原样，不含这些新格式。

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
| 工具栏 | 纯图标按钮（SF Symbols，`NSToolbarDisplayModeIconOnly`），悬停显示中文说明；系统符号缺失时自动降级为文字按钮，不会出现空白按钮；搜索框放在普通 `NSToolbarItem` 的自定义视图里（**不用** `NSSearchToolbarItem`，原因见 BUILD.md 坑点 8），边打字边过滤，无需回车。搜索框宽度取 120pt：统一工具栏下标题与按钮同一行，它多占一点就少放一个按钮，120pt 才能让「打开归档 / 新建归档 / 压缩选项」在默认窗口尺寸下全部常驻（实测见 BUILD.md 坑点 10） |
| 压缩参数 | 收进工具栏「压缩选项」弹出的 `NSPopover`，不占用主界面；面板内两列对齐排布。**面板设置会被记住**，重启后照原样恢复（格式、等级、方法、字典、字长、匹配查找器、固实与分块、线程、分卷、加密算法、文件名加密、压缩头、完整路径、排除 Mac 资源文件、验证完整性、高级区展开状态）。两处刻意不记：密码（明文落盘是安全缺陷，「记住密码」那条路走钥匙串）与「压缩完成后删除源文件」（不可逆的破坏性开关，每次重新勾选更安全） |
| 内容区 | 有归档时是八列表格（`NSTableViewStyleFullWidth`），没有时是居中的空状态（图标 + 标题 + 说明 + 主操作按钮），二者互斥显示，不叠加 |
| 日志 | 默认收起，出错或出现告警时自动展开；也可由工具栏按钮或 ⌘L 开关 |
| 状态栏 | 底部通栏，左侧为当前状态（就绪 / 已载入 N 项 / 进度），右侧为当前压缩参数摘要 |
| 外观 | 全部使用语义色（`labelColor`、`secondaryLabelColor`、`windowBackgroundColor`、`controlAccentColor`、`textBackgroundColor`），浅色与深色外观下自动适配 |
| 列表交互 | 空格预览；**双击**文件走系统 Quick Look、双击目录展开/收起；拖出即解压；列头排序在后台计算，十万条目不会卡住界面 |
| 密码 | 打开加密归档时弹出输入框，其中的「在此 Mac 上记住该归档的密码」默认勾选，密码存入**登录钥匙串**（服务名 `org.7-zip.macos`，账户名取归档的标准化路径）。下次打开同一归档会自动取用，全程无提示；若记住的密码已被拒，该条目会被立即清除，不会反复白试 |
| 窗口尺寸 | 紧凑窗体：内容区默认 560×420、最小 460×320。窄窗下工具栏把放不下的按钮自动收进 `>>` 溢出菜单，仍在可滚动范围内保留完整列 |
| 菜单栏 | 常驻状态图标（SF Symbol `archivebox`，模板图随底色自动反色）。点击弹出「打开归档 / 新建归档 / 打开最近使用 / 显示主窗口 / 隐藏菜单栏图标 / 退出」；图标同时**接受文件拖放**——拖上去即按落点类型压缩或解压，与拖进窗口走同一套判据；可在「显示」菜单里随时隐藏。注意图标受系统菜单栏管理：菜单栏挤满时会被收进 `«` 溢出区（与本应用无关，实测同样条件下其他进程新建的状态项也一样） |
| 菜单 | 按 HIG 补齐标准项：编辑菜单含**撤销 / 重做**（⌘Z / ⇧⌘Z，也作用于搜索框等编辑控件）、剪切 / 拷贝 / 粘贴 / 全选、查找（⌘F 聚焦归档搜索框）；「显示」菜单含日志开关与全屏项，全屏项标题随窗口状态在「进入 / 退出全屏幕」间切换；帮助菜单接入 Apple Help Book，首项由系统替换成可检索的搜索框。此前这些项或缺失（导致 ⌘Z 完全无效）、或指向错误的选择器（⌘F 被日志抽屉的文本查找抢走）、或键位与系统输入法冲突 |
| 列表右键菜单 | 内容随落点变化：行上是条目级动作（预览 / 解压所选… / 拷贝路径 / 删除所选 / 全选），空白处是整档命令（添加文件… / 测试归档 / 在访达中显示 / 重新载入 / 全选）。破坏性项单独一段放最下，与 Finder 的「移到废纸篓」同位置。右键落在**未选中**的行上会先把选中换成它——否则菜单上点「删除所选」删掉的是上一次的选中集，这是最典型的误操作。各项可用性由 `validateMenuItem:` 统一判定，与菜单栏同源 |
| 本地化 | 开发区域为 `zh-Hans`，本地化键取中文原文，因此除英文表外无需维护第二份字符串，跟随系统语言自动切换。构建期核对「源码里每个 `L(@"…")` 都在英文表中有条目」，漏一条即构建失败——否则会在英文系统上静默露出一句中文。除跟随系统外，「显示 › 语言」可显式指定（跟随系统 / 简体中文 / English）；语言表在进程启动时挑定、运行期改不了，切换后会提示重启并提供一键重启 |

> 内容区（表格与空状态）与日志抽屉的 frame 由代码直接计算而非 Auto Layout
> 约束——这是实测踩坑后的约定（`NSScrollView` 由约束定位时会被 AppKit 跳过
> 绘制），原因与完整排查记录见 `BUILD.md` 坑点 7。

### 大归档性能

以十万条目的 ZIP（12.2 MB）实测：建树在后台队列完成，界面不卡；条目由引擎
逐条取用、用完即弃，不再先攒一份完整条目数组，**内存峰值减半**（95.9 MB →
48.8 MB）；列头排序同样移出主线程（124 ms → 4 ms）。数据与做法见 `BUILD.md`
坑点 14、15。

---

## 二、目录结构

```
.
├── 7z2603-src/                上游 7-Zip 26.03 源码 + macOS 适配补丁
│                              （含 DOC/ 许可文件；补丁清单见 dist/build/upstream-macos.patch）
├── dist/                      移植层：源码、构建脚本与产物输出目录
│   ├── app-src/               AppKit 应用源码（main.m、Info.plist、build_app.sh）
│   │   └── Z7StatusItem.{h,m} 菜单栏状态图标：偏好读写 + 拖放运行期装配
│   ├── engine/                引擎内嵌层
│   │   ├── build_dylib.sh     由上游 Format7zF Bundle 构建 lib7z.dylib
│   │   ├── SevenZipEngine.{h,cpp}      C++ 桥接层（归档读写、安全策略、任务取消）
│   │   ├── SevenZipEngineObjC.{h,mm}   Objective-C 适配层（App 实际调用的一层）
│   │   ├── Z7ExtCodec.{h,cpp}  外部编解码器处理器（zstd / lz4 / brotli / lzip / snappy 读写）
│   │   ├── Z7IsoWriter.{h,cpp} 自研 ISO9660 + Joliet 写入器（进程内，零子进程）
│   │   ├── Z7DmgWriter.{h,cpp} DMG 写入器（调系统 hdiutil，唯一子进程例外）
│   │   ├── ext_codecs.sh       探测 Homebrew 静态库（缺失则降级，构建照常成功）
│   │   └── build_engine.sh    构建 lib7zbridge.a + lib7zbridgeobjc.a
│   ├── tests/                 验收测试与工具
│   │   ├── engine_test.cpp    桥接层验收程序（对照官方 7zz 逐项比对）
│   │   ├── objc_test.m        ObjC 适配层验收程序
│   │   ├── verify_engine.sh   桥接层验收套件（158 个用例）
│   │   ├── verify_app.sh      应用包验收（依赖解析 / 部署目标 / 签名 / 真实启动）
│   │   └── build_test.sh, build_objc_test.sh
│   ├── lib/                   构建产物：lib7z.dylib、lib7zbridge*.a
│   ├── ql-src/                Quick Look 扩展源码
│   │   ├── SevenZipPreviewProvider.m   预览提供者（Objective-C）
│   │   ├── EngineListing.mm            进程内引擎列举（链接 lib7z.dylib）
│   │   ├── ArchiveReader.c/.h          纯 C 归档解析器（引擎拒绝时的兜底）
│   │   └── build_ql.sh
│   ├── app-res/               应用图标（.iconset 源 + 生成的 .icns）
│   ├── build/                 打包脚本、手册页、说明文档、卸载脚本
│   │   ├── make_installer.sh  生成 .pkg / .dmg / .tar.xz 与校验和
│   │   ├── package.sh         生成 Homebrew 用的分发包
│   │   ├── mk_tarball.py      可复现归档器（固定顺序/mtime/属主/权限）
│   │   ├── verify_scripts.sh  离线验证安装/卸载脚本逻辑
│   │   ├── build_help.sh      用 hiutil 为帮助书生成搜索索引（构建产物，不入仓库）
│   │   ├── BUILD.md           可复现构建说明（含实测坑点）
│   │   └── uninstall.sh
│   ├── shell/                 zsh / bash / fish 补全脚本
│   ├── homebrew/              Homebrew 公式及其离线校验脚本
│   ├── resources/             安装器欢迎页、自述页
│   │   ├── en.lproj/          英文界面字符串表 + 英文帮助书
│   │   └── zh-Hans.lproj/     中文帮助书（字符串表刻意留空，见第五节）
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

> **发行标签与产品版本是两回事。** 产品版本始终跟上游走（`26.03`，也是
> `.app` 的 `CFBundleShortVersionString` 与 `7zz i` 打印的值），产物文件名
> 用的就是它；发行标签额外带本移植的修订号，当前为 **`v26.03.1`**。所以下载
> 链接里是 `v26.03.1` 而文件名里是 `26.03`。重新发行时只递增标签，产物文件名
> 与公式里的 `version` 都不用动。

> 当前产物为 **ad-hoc 签名**，安装包本身**未经 Apple 公证**。首次打开时若被
> Gatekeeper 拦截，请右键 `.pkg` → **打开**，或在「系统设置 → 隐私与安全性」
> 中允许。如需正式分发，请参见 `dist/build/BUILD.md` 第七节完成
> Developer ID 签名与公证。

### 3.2 免安装命令行包

```bash
curl -LO https://github.com/XINKEJU/7-Zip-macOS/releases/download/v26.03.1/7-Zip-26.03-macOS-arm64.tar.xz
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
make test        # 桥接层验收（对照官方 7zz 逐项比对，158 个用例）
make objc-test   # ObjC 适配层验收（App 实际调用的那一层，95 个用例）
make appcheck    # 应用包验收：依赖解析 / 部署目标 / 签名 / 真实启动（42 个用例）
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
2. **列表由进程内引擎给出，不调用 `7zz`。** 调用内嵌 `7zz` 需要
   `com.apple.security.inherit`，而该权限只在具备真实团队身份的签名下生效，
   `posix_spawn` 会以 `EPERM` 失败。扩展因此直接链接 `@rpath/lib7z.dylib`
   （`EngineListing.mm`），由引擎在**扩展自己的进程内**读条目表——当前产物里
   已不含任何 `7zz` 引用。只有当引擎拒绝该文件时，才回退到内置的轻量解析器
   （`ArchiveReader.c`，读 ZIP/TAR/GZIP 条目表；其余仅识别容器）。

因此与早期版本不同，Quick Look 现在对**引擎支持的所有格式**都给出完整文件
列表，而不再只覆盖 ZIP / TAR / GZIP：

| 类型 | 行为 |
|---|---|
| 引擎支持的全部格式（7z、ZIP/ZIP64、TAR 各变体、GZIP、BZip2、XZ、Zstd、LZ4、Brotli、lzip、Snappy、RAR、CAB、ISO 9660、DMG、WIM …） | 完整文件列表：名称、原始大小、压缩后大小、修改时间、属性；含总文件数/文件夹数 |
| 引擎拒绝、但内置解析器认得（ZIP / TAR / GZIP 系列） | 由 `ArchiveReader.c` 兜底给出条目表 |
| 只能识别容器（如分卷不完整） | 给出容器元信息与明确说明 |
| 截断或损坏 | 明确报错（例如「ZIP 结束记录（EOCD）缺失」），不静默失败 |

> 「扩展不派生子进程」是这条设计背后的硬约束：ad-hoc 签名下 `7zz` 起不来。
> 这也是本项目把引擎做成 `lib7z.dylib`、全程进程内调用的根本原因，DMG 创建是
> 唯一的例外（DMG 无进程内等价实现，见第八节）。

---

## 七、验证

三条门禁都不需要提权，全部通过才算改动完成：

| 门禁 | 内容 | 规模 |
|---|---|---|
| `make test` | 桥接层对照官方 `7zz` 逐项比对（`engine_test.cpp` + `verify_engine.sh`，共 20 节） | **158 项** |
| `make objc-test` | Objective-C 适配层（`objc_test.m`），含菜单栏状态图标的装配与拖放行为、压缩选项持久化、列表右键菜单结构 | **95 项** |
| `make appcheck` | 应用包：包结构、本地化与帮助书、动态库依赖解析（真正解析到磁盘）、部署目标、签名、进程模型 | **42 项** |

其中 ISO / DMG 用三重独立手段交叉验证，避免「自己写、自己验」的循环论证：

1. **结构解析**：自研 Python 解析器按 Joliet 卷描述符还原完整目录树，与源目录
   逐字节比对（含中文文件名），并断言 `.` / `..` 为 ECMA-119 要求的单字节
   `0x00` / `0x01`。
2. **上游交叉**：用上游 `7zz` 的 ISO / DMG 读取器打开自产镜像，列出条目并解包
   比对内容。
3. **系统挂载**：`hdiutil attach` 真实挂载，读回文件核对内容。

ISO 另有 ECMA-119 6.9.1 路径表合规性断言（父目录号自洽且小于自身编号、条目按
「层级 → 父目录号 → 标识符」升序）。DMG 另用 `hdiutil imageinfo` 验证产物结构。

菜单栏状态图标的拖放单独有一套断言。`NSStatusBarButton` 由系统创建、既不能子类化
也不能替换，拖放方法只能用 `class_addMethod` 在运行期补上；而 `NSView` 本身就带同名
方法，于是「查得到方法」和「我们装过」是两回事——拿前者当幂等守卫会让整段装配静默
失效，界面上只表现为「拖上去没反应」，不报错也不留日志。因此 `objc_test` 不只断言
「装配成功」，还把每个方法的类型编码与**编译器**为同一签名生成的编码逐条比对，并造一个
`NSDraggingInfo` 替身把「粘贴板里的文件 URL → 接收方」这条链路真跑一遍。本机合成不了
真实拖放事件，这是该功能唯一可行的端到端验证手段。

`make verify` 另行覆盖安装/卸载逻辑与 Homebrew 公式一致性：

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
2. **新增格式只在应用里，`7zz` 命令行没有。** zstd / lz4 / brotli / lzip / snappy
   创建与解压、ISO 与 DMG 创建都由应用（`lib7zbridge.a` 引擎接口）提供；`7zz`
   保持上游原样，`7zz a -tzstd` / `-tiso` 会报错退出。取舍理由见第一节。
3. **四个外部库需在构建时链入。** brotli 需要 `libbrotli`、lzip 需要 `liblzma`、
   zstd / lz4 同理；本机未安装某库时，对应格式会整体编译出去（构建仍成功），
   此时该格式的文件无法打开。snappy 是自实现，不受影响。
4. **链入的第三方静态库可能抬高实际系统要求。** 官方发行的二进制是链着
   Homebrew 的 `libzstd` / `liblz4` / `libbrotli` / `liblzma` 构建的，而这些库本身
   是按较新 macOS 编译的，链接时会出现 `was built for newer 'macOS' version (14.0)
   than being linked (11.0)` 警告。四个库只依赖 libc 中最早期的接口，因此实测在
   11.0 上可用；但若将来某个库版本真的用到新系统 API，就需要自行以正确
   deployment target 重新编译。详见 `BUILD.md`。
5. **DMG 创建是全项目唯一的子进程调用。** 它通过 `posix_spawn` 调系统
   `/usr/bin/hdiutil`——DMG 是 Apple 专有格式，没有进程内等价实现。其余所有
   归档操作（含 ISO 创建）都在进程内完成，`make appcheck` 对此有断言。
6. **只支持 Apple Silicon。** 2026-09-24 起不再构建 x86_64 切片——它占每个
   可执行体体积的近一半，而 Intel Mac 已无在售机型。Intel 机器会直接报
   「bad CPU type in executable」（Rosetta 2 是把 x86_64 翻译成 arm64，方向相反，
   帮不上忙）。上游源码未改，恢复 x86_64 只需把各构建脚本里的分支加回来。
7. **最低系统版本 11.0**（首个支持 Apple Silicon 的版本）；应用扩展为 12.0。
8. **不提供 32 位支持。**
9. **钥匙串的一次性授权提示。** ad-hoc 签名没有固定的团队标识，因此重新构建后
   首次读取已记住的密码时，系统会询问一次是否允许访问（点「始终允许」后不再
   打扰）。换成 Developer ID 正式签名即可消除该提示。
10. **菜单栏状态图标受系统的菜单栏管理。** 菜单栏上第三方图标较多时，macOS 会把
   新出现的图标收进左侧的 `«` 溢出区，此时图标不出现在菜单栏上（点 `«` 才看得见）。
   这是系统的收纳行为而非本应用的缺陷——实测在同样的菜单栏状态下，从另一个进程
   新建一个状态项也得到同样的结果。用户可 ⌘-拖动调整图标顺序，或在「显示」菜单里
   关掉它。
11. **帮助书只提供中英两份。** 帮助菜单的搜索框索引由系统 `hiutil` 在构建时生成，
   因此改动帮助页面后需要重新构建应用才能让搜索命中新内容。

---

## 九、许可证

本项目是上游 7-Zip 的**衍生作品**，整体适用与上游相同的条款：

- **GNU LGPL v2.1 或更高版本** —— 全文见 [`LICENSE`](LICENSE)
- **unRAR 许可证限制** —— 二进制编入了 RAR 解压引擎，因此随附该限制文本；
  可解压 RAR，但**不得**用于开发 RAR 兼容压缩器
- 源码中个别文件适用 BSD 2/3-clause（LZFSE、Zstandard、XXH64 解码）
- 本移植新链入的 zstd / lz4 / brotli / liblzma 静态库适用 BSD 3-clause /
  BSD 2-clause / MIT / 0BSD（仅当构建机装有对应库时才被链入；见
  `THIRD_PARTY.md` 1.2 节）

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
- **Apple / Facebook / Yann Collet / Google** —— LZFSE、Zstandard、LZ4、Brotli、
  XXH64 的算法与实现
