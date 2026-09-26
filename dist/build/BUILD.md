# 7-Zip 26.03 macOS 原生构建与安装包 — 可复现构建说明

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
make -f ../../cmpl_mac_arm64.mak      # arm64（本项目当前唯一构建的架构）
make -f ../../cmpl_mac_x64.mak        # x86_64（上游提供，本项目已不再编译）
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
   145pt），故 `main.m` 中为 `drop` 补了一条最小宽度约束（460），并在
   `setFrameAutosaveName:` 返回 `NO`（首次运行）时显式给回 560×420。

**窗口尺寸（2026-09-24 收紧为 Keka 风格小窗）**：内容区默认 560×420、最小
460×320，`drop` 的最小宽度约束（460）与之取齐。实测两种尺寸下工具栏、空状态、
状态栏、列表均正常绘制。两点容易踩空：

1. **改默认尺寸必须同时给 `setFrameAutosaveName:` 换键名。** 该键一旦写进
   defaults（`NSWindow Frame 7ZipMainWindow = "341 136 1040 732 …"`），旧框架
   就会在每次启动时覆盖新默认值——只改 `setContentSize:` 的数字是改不动的，
   界面看起来像"改了没生效"。当前键名 `7ZipMainWindow2`。
2. 窄窗下工具栏会把放不下的按钮自动收进 `>>` 溢出菜单（560pt 下常驻
   `打开归档 / 搜索框 / >>`），这是 `NSToolbar` 行为，不需要手工裁剪
   `toolbarDefaultItemIdentifiers`。**但自定义视图的 item 必须把按钮的
   `target`/`action`/`image` 转给 item**（`itemForItemIdentifier:` 末尾三行）：
   溢出菜单项执行的是 **item 自己**的 action，只设 `view` 会让菜单项目标为
   nil、被系统自动禁用——表现为「按钮在工具栏上能点，被收进 `>>` 后点了毫无
   反应」。实测对照：修复前溢出菜单里「压缩选项」「日志」均为灰色不可点。

验证窗口尺寸不必改源码重建：直接写
`defaults write org.7-zip.macos.app "NSWindow Frame 7ZipMainWindow2" "200 220 460 404 0 0 1470 923 "`
后重启应用即可（字符串末尾的空格与屏幕矩形字段是 AppKit 的格式要求），
验完记得 `defaults delete ... "NSWindow Frame 7ZipMainWindow2"` 还原。

若日后要改回约束布局，请先把上面 7 项变量逐一对齐到「能显示」的那一组，并
用 `screencapture` 实测，不要只凭 `frame` 数值判断正确性——**布局数值正确与
内容被绘制是两件事**。

### 坑点 8：工具栏搜索框的编辑事件会被 `NSSearchToolbarItem` 吞掉

`NSSearchField` 放进 `NSToolbar` 时**不要**用 `NSSearchToolbarItem`。该 item 会连
属性、约束和编辑事件一起接管（SDK 原文 “the field properties and layout
constraints are managed by the item”），实测（2026-09-24）接管得非常彻底：

- 在框里打字，`delegate` 的 `controlTextDidChange:` **一次都不回调**；
- `NSControlTextDidChangeNotification` 也**一次都不投递**（把观察者放宽到
  `object:nil` 同样收不到），而 `searchField.delegate` / `.target` 打印出来确实
  就是 `MainViewController`——配置是对的，回调就是不来；
- 字段编辑器自己的 `NSTextDidChangeNotification` 也不发；
- 只有**编辑提交（回车）**时才一次性吐出回调——用户看到的就是
  「**输入后必须回车才能检索出来**」。

把搜索框放进**普通 `NSToolbarItem` 的自定义视图**（和其余按钮同一机制）后，
`delegate`/`target` 归自己管，同时给 `visibilityPriority = High` 让紧凑窗口
优先保住它。此外还加了一条**轻量轮询兜底**（`buildCompressionControls` 里的
`searchPollTimer`，0.15s 比较一次 `stringValue`）：注入式输入与中文输入法的
组合文本（marked text）阶段 AppKit 本就不发上述任何通知，只靠事件通道仍会漏；
文本值本身随时可读，轮询确保任何输入方式（键入、输入法、粘贴）都实时过滤。
定时器要 `addTimer:forMode:NSRunLoopCommonModes`，否则滚动列表时会被暂停。

**验证要点**：用 System Events 注入按键时，macOS 的输入法会介入（屏幕会弹出
候选条，`winid2` 里多一个 `436x31` 的输入法窗口），这条路走的是 marked text，
无法复现真人的逐字符回调——所以判断标准不能只看"有没有回调"，要看**列表行数
是否随输入变化**。选测试关键字时也要注意：若归档顶层只有一个条目，行数恒为 1，
会出现假阳性/假阴性，应挑一个命中数明显不同的关键字（例如 6 个 `report-*.md`）。

**⌘F 的焦点是可靠的**（探针实测 `makeFirstResponder:` 返回 1、首响应者变成
`NSTextView`）。如果注入按键后列表没反应，先确认**应用确实是最前且窗口是 key
窗口**——`set frontmost to true` 之后紧跟的那次 `keystroke` 有时会落空；把
「激活 → 延时 → 注入」放在**同一次 `osascript` 调用**里可稳定复现。
判别菜单栏是否被焦点污染：`AXMain` / `AXFocused` 为 `false` 时，所有依赖 key
窗口的菜单项（连「进入全屏幕」）都会读成禁用，那是读数假象，不是产品缺陷。

### 坑点 9：`NSPopover` 的锚点必须落在窗口的视图层级里

`showRelativeToRect:ofView:preferredEdge:` 的 `ofView:` 传一个**不在任何窗口层级
里**的视图，弹层会**静默不出现**（不报错、不崩溃、不写日志），表现为「点了没反应」。

触发条件正是本应用的紧凑窗口：AppKit 会把工具栏放不下的 item 收进「>>」溢出菜单，
**一旦被收起，该 item 的 view 就被移出工具栏层级**，`button.window` 变成 `nil`。
探针实测：

```
SHOWOPTIONS sender=NSMenuItem isView=0 btnWindow=0 anchorWindow=0
ANCHOR=NSButton bounds=43x24 inWindow=0
（此后没有 AFTER_SHOW —— 执行没能走到下一行）
```

注意溢出菜单项与菜单栏项两者 `sender` 都是 `NSMenuItem`，**不是**按钮，所以
「用 sender 当锚点」这条常见写法在这里天然失效，必须显式回退。

正确做法是三级回退，保证锚点**始终在窗口层级内**：

1. `sender` 是视图且 `sender.window != nil` → 用它（弹层贴着按钮，位置最自然）；
2. 否则 `optionsBtn.window != nil` → 用按钮；
3. 否则退到 `self.view`，取内容区顶边正中的 `1×1pt` 细条当锚点矩形，
   `preferredEdge = NSRectEdgeMinY` 会把弹层挂在该矩形下沿——视觉上正好落在
   工具栏下方居中，用户不会找不到。

**同时注意**：`NSToolbarItem` 只设 `view` 是不够的。溢出菜单执行的是 **item 自己**
的 `target`/`action`，自定义视图不参与菜单，必须把按钮的 `target`/`action`/`image`
原样转给 item，否则那些被收起来的按钮在菜单里会**自动变灰**。

### 坑点 10：紧凑窗口下「哪些工具栏项能常驻」取决于搜索框宽度

统一样式（`NSWindowToolbarStyleUnified`）下标题与工具栏同处一行，默认内容宽
560pt 时空间很紧。搜索框宽度是固定约束，**它多占一点，就少放一个按钮**。同一
窗口下逐个试过的实测结果：

| 搜索框宽度 | 常驻按钮 |
|---|---|
| 190pt | 仅「打开归档」（新建归档、压缩选项都进「>>」） |
| 150pt | 「打开归档 / 新建归档」 |
| **120pt** | 「打开归档 / 新建归档 / 压缩选项」三个全部常驻 |

再往下压就切占位文字（「搜索条目」显示不全），故停在 120。当前取值见
`toolbar:itemForItemIdentifier:willBeInsertedIntoToolbar:` 里搜索项分支的注释。

⚠️ **不要靠提 `visibilityPriority` 来让某个按钮常驻**：实测把「压缩选项」提到
`High` 之后，AppKit 会优先保住两个 `High` 项（它 + 搜索框），**反而把普通优先级的
「打开归档」「新建归档」挤进「>>」**——把最高频的操作藏起来，比原来更糟。常驻
名额只能靠「腾空间」争取，不能靠提优先级抢。

### 坑点 11：中文串在 Mach-O 里是 UTF-16，用 `strings | grep 中文` 会误判

核对"某段代码到底有没有编进产物"时，若用 `strings 主程序 | grep 某中文串`，**永远搜不到**：
Clang 对含非 ASCII 的 `@"..."` 生成 **UTF-16** 存储，二进制里根本不存在它的 UTF-8 字节序列。
而同一段代码里的 ASCII 字面量（NSUserDefaults 键名、selector 名）照常能搜到，于是会出现
"同一个方法里一半字符串在、一半不在"的假象，极易被误判成"源码没编译进去"，然后把时间
浪费在重编上。

按编码分别搜才对：

```bash
python3 -c "d=open('dist/7-Zip.app/Contents/MacOS/7-Zip','rb').read()
print('目标已存在同名文件时'.encode('utf-16-le') in d)"
```

### 坑点 12：不要按「对象大小」估算短字符串的内存收益

优化条目内存时曾按 `NSString` 对象大小估算"每条目的 CRC/属性串约 190 B"，据此认为
惰性化能省十几 MB。实测（10 万条目）**只有 ~3 MB**：arm64 上 **11 个 UTF-8 字符以内
的 `NSString` 是 tagged pointer**，`%08X` 的 CRC 串（8 字符）和 9/10 字符的属性串
**根本不分配堆内存**，值就存在指针里。

唯一真正上堆的是 `AttributeTextFromMode()` 里的 `stringWithUTF8String:`（它不产生
tagged pointer），也就是那 3 MB 的来源。

结论：短字符串的惰性化主要省的是**构造开销（CPU）**，不是内存。要量内存只能实测
（`task_vm_info.phys_footprint`，注意 `mach_task_basic_info` 里没有这个字段），
不能按类字段推算。

### 坑点 13：`NSOpenPanel` 的 accessoryView 在 macOS 26 默认被收进「显示选项」

解压面板的「目标已存在同名文件时」下拉框挂在 `NSOpenPanel.accessoryView` 上。
macOS 26 的面板**默认不展开**它——右下角只多一个「显示选项 / 隐藏选项」开关。
首次验证时既看不到控件、AX 树里也查不到，很容易误判为"accessoryView 没生效"。

验证要先点开「显示选项」，控件才会出现在 `splitter group 1` 下：

```bash
osascript -e 'tell application "System Events" to tell process "7-Zip" \
    to tell splitter group 1 of window "打开" to click button "显示选项"'
```

⚠️ 该按钮位于 `splitter group` 之内，直接对 `window` 点击会报 **-1728**。
点开后再查 `pop up button 2 of splitter group 1 of window "打开"` 即可读到当前策略。

### 坑点 14：大归档的内存峰值来自「先取全量条目，再建树」

打开十万条目归档时，原实现先 `allItems` 攒一份 10 万个 `Z7Item` 的数组（实测 ~58 MB），
再据此建 UI 树，两份结构同时驻留。改为**逐条 `itemAtIndex:` 流式建树**后，`Z7Item`
用完即弃（`@autoreleasepool` 分块），峰值降约一半：

| 路径 | 耗时 | 峰值 |
|---|---|---|
| `allItems` + 建树 | 0.250 s | **95.9 MB** |
| 逐条建树（现方案） | 0.253 s | **48.8 MB** |

前提是引擎侧 `getAllItems` 本来就是循环调 `getItem`（`SevenZipEngine.cpp`），逐条取
没有任何额外代价。`Z7Archive` 的条目表在打开时就已读入，`itemAtIndex:` 是 O(1)。

顺带清掉的两处浪费：

- **一份只写不读的「路径 -> 条目号」字典**（`indexByPath`）：树节点自带 `index`
  字段，`indicesForNodes:` 一直直接读节点，那份十万条字典从未被任何代码查询过，
  白白占内存与建表时间。
- **建树第二遍的排序**：原为「全部路径排序后逐条反向切分」，实测 124 ms；改为遍历
  字典键（天然去重）并由 `Z7EnsureAncestor` 递归补全中间目录（与处理顺序无关，
  本就不需要先排序）后降到 **4 ms**。

### 坑点 15：列头排序不能就地排

`outlineView:sortDescriptorsDidChange:` 原先直接对每一层 `children` 就地
`sortUsingComparator:`。十万条目下这是 O(n log n) 次 `localizedStandardCompare`，
全压在主线程上。挪到后台时注意：**不能让后台线程就地排序共享的 `children` 数组**——
主线程可能正在遍历同一批节点渲染。

做法是「后台只算、主线程只搬」：主线程先收集各层数组的引用（O(n) 指针搬运），
后台对每层 `sortedArrayUsingComparator:` 生成**有序副本**（不触碰原数组，因此后台
运算期间主线程继续渲染是安全的），回主线程再 `setArray:` 写回并 `reloadData`。
作废机制沿用搜索那套 `contentGeneration`。

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

## 三、构建引擎（arm64）

```bash
cd 7z2603-src/CPP/7zip/Bundles/Alone2
export MACOSX_DEPLOYMENT_TARGET=11.0

make -B -j8 -f ../../cmpl_mac_arm64.mak     # → b/m_arm64/7zz
```

说明：
- 编译告警等级为 `-Wall -Wextra -Weverything -Werror -Wfatal-errors`，源码零告警通过。
- arm64 目标含手写汇编（`Asm/arm64/LzmaDecOpt.S`）。
- **不再编译 x86_64。** 2026-09-24 起本项目只发行 arm64：x86_64 切片占每个
  可执行体体积的近一半，而 Intel Mac 已无在售机型。上游 `cmpl_mac_x64.mak`
  原样保留在源码树里，只是不再被调用；恢复方式见仓库 Makefile 文件头。

## 四、取出引擎可执行体并签名

```bash
cd dist && mkdir -p build
cp -f <src>/b/m_arm64/7zz build/7zz
codesign --force --sign - --timestamp=none build/7zz

lipo -archs build/7zz          # → arm64
codesign --verify --strict build/7zz
```

签名必须做：未签名的 arm64 可执行体会被内核直接拒绝执行。此前这一步还包含
`lipo -create`（把 arm64 与 x86_64 两个切片合成通用二进制），单架构后不再需要。

---

## 五、组装负载与打包

集成安装包由 `build/make_installer.sh` 一次产出。它搭建两棵负载树，分别打成
组件包，再由 `productbuild` 合成带选择界面的分发安装包：

```
root-cli/usr/local/                    组件包 com.7-zip.7zz   → /usr/local
├── bin/7zz                            (755, arm64)
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
    └── Contents/MacOS/7ZipQuickLook   (扩展可执行体；进程内解析归档)

> **为什么应用包里一份 `7zz` 都没有？**
> 前端自身的归档操作全部通过 `lib7z.dylib` 在**进程内**完成（技术方案 §1.3），
> 不再派生 `7zz`。Quick Look 扩展运行在 App Sandbox 中，无法加载应用包的
> 动态库，因此扩展改为**进程内解析**（`ql-src/ArchiveReader.c`：ZIP/ZIP64、
> TAR、GZIP 给出完整条目列表，BZIP2/XZ/ZSTD/7z/RAR/CAB/ISO 识别容器并给出摘要）。
> 早期版本曾把一份 `7zz`（6,012,576 B）放进 appex 并签以
> `com.apple.security.inherit`；但该权限属**受限权限**，**ad-hoc 签名
> （`codesign --sign -`，`TeamIdentifier=not set`，本项目的分发方式）
> 无法使其生效**。2026-09-24 实测扩展自身日志：
> `posix_spawn 失败：Operation not permitted (errno 1)`、`engine run: raw=0 bytes`、
> 内容全部来自 `native reader`——即引擎**从未成功执行过一次**，那份占整个
> `.app` 48% 的副本属纯死载荷，已移除（`.app` 由 12.58 MB 降至 6.57 MB）。
> 证据：`~/Library/Containers/org.7-zip.macos.quicklook/Data/tmp/7zip-quicklook.log`。
> 若日后改用 Developer ID 签名，可按 `ql-src/build_ql.sh` 头部注释恢复该路径。

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
tar -cJf 7-Zip-26.03-macOS-arm64.tar.xz -C root-cli/usr/local .
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
sh dist/build/package.sh && shasum -a 256 dist/7zip-macos-26.03-macos-arm64.tar.gz
sh dist/build/package.sh && shasum -a 256 dist/7zip-macos-26.03-macos-arm64.tar.gz
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
| 架构 | `lipo -archs 7zz` | `arm64`（**不含** `x86_64`） |
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
make test        # 桥接层验收，对照官方 7zz 逐项比对（88 个用例）
make objc-test   # ObjC 适配层验收（App 实际调用的那一层，44 个用例）
make appcheck    # 应用包验收（含真实启动与进程模型检查，20 个用例）
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
  也就无法派生辅助进程。当前实现因此改为**扩展内直接解析归档**
  （`ql-src/ArchiveReader.c`），不再依赖任何子进程——好处是 ad-hoc 签名的分发
  版本同样能正常预览（2026-09-24 实测确认，见上文"为什么应用包里一份 7zz 都没有"）。
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
