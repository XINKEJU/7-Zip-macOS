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

### 坑点 16：写 ISO9660 时六处「看不出来但读取器一定会挑」的地方

`dist/engine/Z7IsoWriter.cpp` 是自研的 ISO9660 + Joliet 写入器。格式本身不复杂，
但下面六条要么是「写错了自己解析也对、只有别的读取器报错」，要么会让产物每次
都不一样，全部实机踩过。**判别工具是上游 `7zz l` + `hdiutil attach`，不要只看
自己的解析器**（自研解析器与自研写入器很容易犯同一个错）。

1. **目录记录的日期字段是 7 字节，不是 8 字节。** 这 7 字节是
   `年-1900, 月, 日, 时, 分, 秒, GMT 偏移(以 15 分钟为单位)`——**时区就在第 7 字节**。
   多写一个时区字节，后面所有字段整体后移一位，`namelen` 落到偏移 33 而不是 32，
   于是「自己能解析、7zz 报错」。
2. **卷描述符里路径表的四个字段顺序是 L / L-可选用 / M / M-可选用**，即偏移
   **140 / 144 / 148 / 152**（不是 L、M、0、0）。写错顺序，7-Zip 会把 M 的值
   当成「L 的可选路径表」读，指向一个越界扇区，直接报
   `Cannot open the file as archive`。相关字段：逻辑块大小在 128，路径表大小在
   132（LE）/136（BE）。另注意 **M 路径表的位置是大端存储**（148），按小端读会
   得到 `0x14000000` 这种荒谬值。
3. **`.` 与 `..` 必须是单字节 `0x00` 与 `0x01`，不是 UTF-16 的 `"."` / `".."`。**
   7-Zip 的 `IsSystemItem()` 判据是「标识符长度 == 1 且字节 < 2」。写成 UTF-16
   时它不认，会把 `.` 当成真目录递归下去，报 **`Self-linked directory`**，并且
   列表里每个目录都会多出一份重复条目。卷描述符内嵌的根目录记录同理：标识符
   长度 1、值 `0x00`。
4. **路径表要按（层级 → 父目录号 → 标识符）升序，父号是「父目录的编号」而不是
   自身编号。** 编号就是条目在路径表中的 1-based 位置（**路径表条目里没有「编号」
   字段**，这点很容易搞混）。父号写成自身编号时，`7zz` 和 `hdiutil` 都能容忍，
   但 Windows CDFS 等会按此顺序做二分查找，顺序不对就查不到目录。实现见
   `orderDirs()`：先真 BFS 定层，再逐层按（父号, 名字）排序并重编号，父目录
   总在更小的层，所以处理到第 L 层时父号已经是最终值。
5. **目录记录不能跨越扇区边界。** 一条记录若会跨到下一个 2048 字节扇区，必须
   先用 0 把当前扇区填满。计算大小（`computeSizes`）与写入（`writeDirRecord`）
   必须用**同一套**填充规则，否则算出的 `dirBytes` 与实际写入不符。
6. **同一目录内的目录记录要按标识符升序**（ECMA-119 9.3），且子项顺序不能跟着
   `readdir` 走——那样同一输入每次产出的 ISO 字节都不同。做法是：先按原始名排序
   再做重名去重（`_2`/`_3` 后缀的分配顺序因此确定），最后按 Joliet 标识符排序。

验证手段（`verify_engine.sh` 第 16 节）：自研 Python 解析器逐字节比对 + 上游
`7zz` 读取解包比对 + `hdiutil` 真实挂载读回，三条独立路径；另有 ECMA-119
6.9.1 路径表合规断言。

### 坑点 17：DMG 与「零子进程」原则的唯一边界

本项目全程进程内运行引擎（`lib7z.dylib`），`make appcheck` 有双向断言。**DMG
创建是唯一被许可的子进程例外**，理由与约束都写在这里，改代码前先读：

- **为什么必须例外**：DMG（UDIF/UDZO）是 Apple 专有格式，公开文档不足，没有可
  依赖的进程内实现。`hdiutil` 是系统自带工具，不引入第三方依赖。
- **怎么调**：`dist/engine/Z7DmgWriter.cpp` 用 **`posix_spawn`**（不是 `NSTask`），
  因此主程序仍然**不引用 `NSTask` 类**，`verify_app.sh` 那条「未引用 NSTask」
  的断言依旧成立。
- **把子进程数量压到 1**：暂存目录的建立、文件递归拷贝、以及事后清理全部用
  C++ 完成，不额外派生 `cp` / `rm`。整条 DMG 创建路径只起一个 `hdiutil`。
- **断言怎么放宽**：`verify_app.sh` 第 5 节统计子进程时把 `hdiutil` 列入白名单，
  `7zz` 仍然一律禁止。打开归档不会触发 `hdiutil`，所以常规路径下子进程数仍是 0。
- **不要在别处模仿这条例外**。任何新的子进程调用都必须先回到这里更新理由，
  否则两条断言会立刻变红——那是设计意图，不是障碍。

### 坑点 18：外部编解码器的两个「静默失败」陷阱

上游 26.03 没有 lz4 / brotli / lzip / snappy，zstd 也只有解码器。补法是在 `Z7ExtCodec.cpp`
里做独立于上游注册表的处理器（约定：不改上游源码）。踩到两个表面症状相似、根因
完全不同的坑：

1. **悬垂指针。** 注入处理器列表时若用**局部** `std::vector<ExternalCodec>` 再
   把 `&vec[k]` 存进 `HandlerEntry`，函数返回后指针立刻失效——症状是「处理器
   枚举得到、一到打开就报无法识别」。必须让
   `GetExternalCodecs()` 返回**静态**向量的引用。
2. **去重把外部处理器误删。** `OrderHandlersForPath` 按 `memcmp(clsid)` 去重，
   而外部处理器的 `clsid` 从未初始化（栈垃圾），会偶然与某个上游格式（如 gzip）
   的 CLSID 相等，于是被当成重复项丢掉——症状同样是「打不开」，但根因在排序
   阶段。规则改为：**只要比较双方有一方是 `extCodec`，就改用指针判重**，外部
   处理器与上游永不相等，直接放行。
3. 相关的还有 `ClsidByHandlerName`：它按名字找 CLSID 创建归档，遇到外部条目会
   返回一个占位 GUID，导致「`create lz4` 返回成功却产出一个 ZIP」。枚举时必须
   `if (hs[i].extCodec) continue;`，并在创建入口对 decode-only 格式直接报错。

判定技巧：**看症状分不开「没进候选」与「进了又被丢」，就在候选列表与最终选中
处各打一条日志**。本次两次误判都是靠这个区分开的。

### 坑点 19：补格式时三个「构建成功但格式不见了 / 一测就崩」的坑

后来把外部编解码器从 3 个扩到 5 个（zstd / lz4 / brotli / lzip / snappy，全部读写），
又踩到三个：

1. **测试模式没有输出流 —— 漏判直接段错误。** 7-Zip 在 `-t`（只校验不落盘）时给
   解码器的 `ISequentialOutStream *` 是 **NULL**。任何「先写再判空」的写法都会
   解引用空指针（症状：`engine_test test <损坏的归档>` 直接 `Segmentation fault: 11`，
   而正常解压完全正常）。修法是把 `WriteAll()` 改成 `out == NULL` 时直接返回成功，
   并**保持字节计数**——这样 CRC / 长度校验照常生效，而不是被短路掉。所有格式共用
   这一个出口，所以只需要改一处。新增格式时务必给 `-t` 补一条断言。
2. **`_ext_codec_accept` 的第二个参数是宏名，传错会静默少一种格式。** 探到 liblzma
   时若写成 `_ext_codec_accept lzip lzma`，产出的是 `-DZ7_HAVE_LZMA=1`，而代码里
   守卫是 `#ifdef Z7_HAVE_LZIP` —— 格式被整体编译出去，**构建照常成功**，
   只有跑门禁才发现「`create lzip` 不可用」。宏名一律跟**格式名**走，不跟实现它的
   库走；改完顺手 `nm` 或跑一次 `engine_test formats` 核对。
3. **别名必须在 `CanonicalFormatName` 里归一，不能只靠扩展名表。** `br` / `lz` / `sz`
   这些短写在命令行与下拉框里都会出现，若不归一就直接进 `FindExternalCodec`，
   落空后的报错是「不支持的压缩格式」——听起来像格式没编译进来，实际只是名字没对上。
   当前映射：`br→brotli`、`lz→lzip`、`sz→snappy`（`zst/zstd`、`lz4` 本身即规范名）。

### 坑点 20：lzip 与 snappy 的格式细节（自研容器的验收点）

这两种上游完全没有，也不适合直接套库，实现要点与**必须钉住的断言**：

- **lzip**：6 字节头 `"LZIP" | version(=1) | DS`，`DS` 低 5 位是 log2(基准字典)，
  高 3 位是「减掉 1/16 的份数」；体是 LZMA-302eos 原始流（lc/lp/pb = 3/0/2，**必须
  带 EOS marker**）；尾 20 字节 `CRC32 | 原始长度 | 成员总长`，全小端。
  用 liblzma 的公有 `LZMA_FILTER_LZMA1` 自建容器即可（liblzma 内部虽有
  `lzma_lzip_decoder`，**没有公有头**，别用）。**尾部三因子要逐个校验**：只查 CRC
  会漏掉「长度字段被改」这一类损坏。多成员按顺序串接要能解。
  独立交叉验证只能靠 `xz --format=lzip`（它**只解不压**），输入侧样本用 Python 的
  `lzma` 模块按规范拼——否则「自产自解」是循环论证。
- **snappy**：两种容器。裸格式 = `varint 原始长度` + 元素流（literal / COPY_1 / COPY_2 /
  COPY_4）；分帧格式（`.sz`）= 10 字节 `FF 06 00 00 "sNaPpY"` + 块
  `[type(1)][len(3, 小端)][掩码CRC(4)][data]`，单块原始数据 ≤ 65536。
  解码器**按头部自动识别**两种（裸格式没有魔数）。
  掩码 CRC 用的是 **CRC-32C（Castagnoli, 0x82F63B78）**，不是 zlib 的 CRC-32，
  而且要先掩码 `((x>>15)|(x<<17)) + 0xA282EAD8` —— 手写时这两步最容易只做一半。
  写测试样本时注意：**未压缩块（type 0x01）的数据是裸字节，不是一条 snappy 流**，
  想从分帧产物里抠出「裸流」必须让输入可压缩，保证编码器选的是压缩块（0x00）。
  另外 `COPY` 允许重叠引用，复制要**逐字节**做，不能用一次性 `memcpy`。

### 坑点 21：上游源码整棵树是 CRLF —— 动它之前先想清楚

`7z2603-src/` 里每个文件都是 **CRLF** 行尾（上游发布包如此；实测未改动的文件与
官方 tarball 的 CR 数量逐个相等）。用文本模式读写这些文件会**静默**把 CRLF 转成
LF：Python 的 `Path.read_text()/write_text()` 默认走 universal newlines，一次
「只加个注释头」的操作就能把 8 个文件整体改成 LF。

后果不在文件本身，而在**补丁**：`dist/build/upstream-macos.patch` 是按行比对的，
行尾全变 ⇒ 每个改过的文件都退化成「整文件替换」hunk，补丁从 14 KB 涨到 373 KB。
而 `patch` 仍能施加、构建照样成功、`--check` 的标记也照样命中 —— 只有对比补丁
体积才看得出来。这个坑真实发生过一次。

规则：

- 改上游文件一律按**字节**读写并沿用原有行尾（`add_mod_notices.py` 即如此实现）。
- 改完必须重生成补丁：`make upstream-patch-regen PRISTINE=<干净原版目录>`。
  该脚本把新补丁施加到干净原版上，要求结果与工作树**逐字节一致**才通过。
- 补丁两侧时间戳被固定在脚本里，因此同一棵树重生成多少次都得到同一个 sha256；
  **若某次重生成后 sha256 变了，说明工作树真的变了**，不要当成噪声忽略。

另一个相关约束：给被改文件补 LGPL 要求的「已修改 + 日期」声明时**只能增行、
不能改行**。验证手法是和「旧补丁施加出来的树」做 diff，要求**删除行数为 0**。

---

### 坑点 22：`NSMenuItem` 的 `keyEquivalentModifierMask` 默认是 ⌘，不是「无修饰」

想表达「按空格预览」时写

```objc
[[NSMenuItem alloc] initWithTitle:@"预览" action:@selector(togglePreview:) keyEquivalent:@" "]
```

得到的其实是 **⌘空格**（实测 `keyEquivalentModifierMask == NSEventModifierFlagCommand`，
即 `0x100000`）——而 ⌘空格 被系统输入法占着，按下去只会切输入法。要么显式
`item.keyEquivalentModifierMask = 0`，要么干脆留空 `keyEquivalent` 并只作鼠标入口
（当前实现选后者：「预览」在菜单里不带快捷键，靠列表空格键生效）。

顺带记一条实测结论：**无修饰的空格不会被 `NSMenu performKeyEquivalent:` 接受**，
所以列表的空格预览与菜单项不会互相抢键，不必为它们做取舍。

### 坑点 23：菜单项缺失会让标准快捷键「完全失效」，而不只是「没有菜单入口」

实测：**菜单里没有 `undo:` 项时，⌘Z 彻底不好使**——`performKeyEquivalent:` 直接返回
`NO`，响应链里根本没有入口。这一点反直觉：一般以为快捷键只是菜单的捷径。

按 HIG 补齐后还有一个细节值得记：`undo:` / `redo:` 只需挂在菜单上，**不需要设 target**。
`undo:` 仅由 `NSWindow` 实现（`NSResponder` / `NSView` / `NSApplication` 都没有），
`NSWindow` 会把它转发给当前 first responder 的 `undoManager`，因此同一个菜单项对搜索框、
密码框都自然生效。

同理两条「选择器被别的东西抢走 / 名字不对」的坑：

- **`performFindPanelAction:` 会被 `NSTextView` 抢走。** 日志抽屉是 `NSTextView`，
  焦点在它上面时 ⌘F 会拐去开文本查找面板，而不是聚焦归档搜索框。改用自定义
  selector（`focusArchiveSearch:`）即可免疫。另外 **同一个等价键只有第一条菜单项
  会被认**，所以 ⌘F 只保留在编辑菜单，帮助菜单那条只作鼠标入口。
- **全屏菜单项的标题无法自动切换。** `NSWindow` 实现了 `toggleFullScreen:`，它会
  先于窗口控制器成为菜单项的 target，标题就不归调用方管了。改用自定义 selector，
  再在 `validateMenuItem:` 里按 `styleMask & NSWindowStyleMaskFullScreen` 改标题。

### 坑点 24：`class_getInstanceMethod` 不能当「我装过没有」的守卫

给「系统创建、无法子类化」的对象（这里是 `NSStatusBarButton`）补拖放方法时，本能会写：

```objc
if (!class_getInstanceMethod(cls, @selector(performDragOperation:))) {
    class_addMethod(cls, @selector(performDragOperation:), (IMP)..., "B@:@");
    ...
}
```

**这段判断恒为假**：`class_getInstanceMethod` 会沿继承链往上查，而 **`NSView` 自己就
声明了 `NSDraggingDestination` 的那几个方法**（实测 `performDragOperation:` 的 IMP
落在 AppKit 里）。于是 `class_addMethod` 一次都没执行，整段拖放装配成了死代码——
界面上只表现为「拖上去没反应」，不报错、不留日志。这个缺陷在仓库里真实存在过一段时间。

正确的守卫是「**装的是我们的实现吗**」，且只看本类自己的方法列表（`class_copyMethodList`
不含父类）：

```objc
static Method Z7OwnMethod(Class cls, SEL sel);   // 只扫本类
// 守卫：Z7OwnMethod(cls, @selector(performDragOperation:)) 的 IMP == (IMP)Z7SB_perform
```

诊断手法：`NSStatusBarButton` 与 `NSView` 的 `class_getMethodImplementation` 若相同，
说明我们的方法根本没装上去。

### 坑点 25：`@encode(BOOL)` 是 `B`，不是 `c`

`class_addMethod` 的类型编码是**手写字符串**，写错不会有编译错误，只会在回调时取到
垃圾值。写这个项目的实现时很容易按「BOOL 就是 signed char，所以是 `c`」下笔——本工具链
上实测：

```
@encode(BOOL)            == "B"
@encode(NSDragOperation) == "Q"      // NSUInteger
clang 为 - (BOOL)performDragOperation:(id<NSDraggingInfo>) 生成的编码 == "B24@0:8@16"
```

即 `performDragOperation:` / `prepareForDragOperation:` 应当是 `"B@:@"`，而
`draggingEntered:` / `draggingUpdated:` 是 `"Q@:@"`，其余是 `"v@:@"`。

**别凭印象改这几个字面量**：`objc_test` 里放了一个实现同样协议签名的探针类，拿
**编译器**为它生成的编码当基准，去掉数字（ABI 偏移）后与装上去的逐条比对。这是编码
正确性的唯一事实来源。

同一条线上还有两个 `sort` 类工具陷阱，一并记在这里：

- **`sort -u` 在 UTF-8 locale 下会静默吞行。** 生成 / 核对本地化键集合时，
  `en_US.UTF-8` 下中文串的权重未定义，实测 47 条互不相同的键被并成 12 条。必须给
  **整条管道**的每一段都加 `LC_ALL=C`，不是只给 `grep` 加。
- **`ditto` 才是合并语义。** 目标目录已存在时 `cp -R` 会把源复制到目标**内部**
  （凭空套一层同名目录），而重复构建时帮助书目录一定已经存在。用 `ditto`。

### 坑点 26：`CFBundleDevelopmentRegion` 写 `zh_CN` 是非法标识

`zh_CN` 不是合法的 BCP-47 标识（语言 + 地区要用 `zh-Hans-CN` 或 `zh_CN` 之外的合法
组合），当前实现用的是 **`zh-Hans`**。写错不报错，只会让「找不到翻译时的回退目标」
落到英文上。`verify_app.sh` 对此有断言。

配套的设计取舍：**本地化键取中文原文**（`#define L(s) NSLocalizedString(s, nil)`），
于是漏配翻译时回退成中文（失败模式安全），只需要维护 `en.lproj` 一份表。代价是必须
在构建期核对键集合——源码里每个 `L(@"…")` 都要在英文表里有条目，少一条**不会有任何
运行时症状**，只是英文系统上静默露出一句中文。`build_app.sh` 用 `diff` 拦住它，
缺少 `en.lproj` 时构建直接失败。

### 坑点 27：`CFBundleHelpBookFolder` 一设，帮助菜单第一项就被系统换掉

只要 Info.plist 里有 `CFBundleHelpBookFolder`，AppKit 会把帮助菜单的第一项**替换成
系统的搜索框**——这是行为，不是可以关掉的选项。搜索框要有结果，帮助书必须带一份
`hiutil` 生成的索引：

```bash
hiutil -I corespotlight -C -a -f out.cshelpindex <帮助书 Contents/Resources>
```

索引是构建产物（页面一改就过期），**不入仓库**，由 `dist/build/build_help.sh` 在打包
应用时生成，失败即构建失败。

布局与查找（实测）：

- 帮助书按本地化规则放在 **`<语言>.lproj/<名称>.help`** 下，**不是** `Resources/`
  根目录。`CFBundleHelpBookFolder` 写 `7-Zip.help`，而查找要用「名字 + 扩展名」两个
  字段：`[bundle URLForResource:@"7-Zip" withExtension:@"help"]` —— 实测在中文系统上
  返回 `.../Contents/Resources/zh-Hans.lproj/7-Zip.help`，说明本地化查找是通的。
- ⚠️ **别拿这个 API 去应用包根目录找 `cshelpindex`**，它会返回「未找到」，但那是
  **正常的**：索引在帮助书内部（`<名称>.help/Contents/Resources/`），由帮助书自己的
  `HPDBookIndexPath` 解析。这曾经被误判成一个「定位不到索引」的缺陷，追了一轮才确认
  是查找基准搞错了。
- 验证这一层不能只看目录存在：`verify_app.sh` 用 `osascript -l JavaScript` 走
  `NSBundle`——也就是 AppKit 内部（`registerBooksInBundle:`）用的同一套本地化查找——
  问一次能不能找到，找不到就 FAIL。目录摆错位置时界面上没有任何症状，
  只有这条断言拦得住。

### 坑点 28：列表右键菜单只能走 `menuForEvent:`，`outline.menu` 会变成死代码

`NSView` 有两条路径能给出右键菜单，**只能选一条**：

1. `self.outline.menu = someMenu` —— 静态菜单，AppKit 的 `menuForEvent:` 默认实现会返回它；
2. 重写 `menuForEvent:` 自己构建 —— 这时 `self.menu` 再也没人读。

原实现是第 1 条（一个 4 项的固定菜单）。要按「点在有行的地方还是空白处」给不同内容，
就必须换成第 2 条。**换的时候要把原来那行 `self.outline.menu = …` 删掉**：留着不会报错，
也不会被使用，但会让后来者以为菜单是静态的，改了半天不见效果。

配套的两点：

- 右键落在**未选中**的行上，必须先把选中换过去再过菜单。列表控件里「右键 + 删除」
  如果删的是上一次的选中集，就是纯粹的误操作。
- 各项的可用性交给 `validateMenuItem:`（菜单项 target 指向控制器，AppKit 弹出前会逐项
  调用），与菜单栏共用同一套判据；不要在构建菜单时另写一份。

### 坑点 29：判断「用户选过界面语言没有」必须用 `persistentDomainForName:`

界面语言的覆盖值是 `AppleLanguages`。读它有一个陷阱：

```objc
// ✗ 永远返回非 nil —— 系统会把全局语言偏好注入读取路径
id v = [[NSUserDefaults standardUserDefaults] objectForKey:@"AppleLanguages"];

// ✓ 只看到「我们自己写下的那一份」
NSDictionary *mine = [[NSUserDefaults standardUserDefaults]
                         persistentDomainForName:[[NSBundle mainBundle] bundleIdentifier]];
id v = mine[@"AppleLanguages"];
```

分不清的后果是菜单勾选态永远标不对：「跟随系统」与「显式选了中文」在读出来之后完全同形。

⚠️ 还有一个次序问题：`setObject:forKey:` 之后 `persistentDomainForName:` 可能仍返回
**写盘前**的快照。所以读取前先 `synchronize` 一次——虽然这个 API 平时被劝退，这里恰好
是它真正需要的场景。`make objc-test` 有一条断言专门盯这个组合（写 → synchronize →
`persistentDomainForName:` 立即读回），它红了就说明「重启后记不住」会复发。

### 坑点 30：启动期会把用户存的设置**覆盖**成默认值——比「没存」更隐蔽

压缩选项面板的持久化本身很简单，真正的坑在**时序**：

`loadView` 里控件建好之后会调一次 `formatChanged:` 刷新禁用态，那条路径一路走到
`updateOptionsSummary`——而保存就挂在它末尾。此时控件里还是**硬编码初值**，如果放任
它写盘，用户存了一年的设置会在每次启动时被就地抹掉。

现象和「根本没做持久化」一模一样，但成因相反：不是没存，是启动时被自己覆盖了。

对策是一个放行标志：`restoreCompressionOptions` 完成前置位，`saveCompressionOptions`
开头不满足就返回。**恢复必须在 `formatChanged:` 之前**——否则首帧的联动禁用态是按
默认格式算出来的（例如上次选 zip，字典/字长该灰却是亮的）。

### 坑点 31：重启应用走 `NSWorkspace`，不要用 `NSTask`

语言切换需要重启才生效（语言表在进程启动时挑定）。重启自己不能用 `NSTask`/`fork`：
本仓有一条硬约束「归档操作零子进程」，`verify_app.sh` 会**真实统计运行期子进程数**，
除系统 `hdiutil` 白名单外一个都不许有。

`NSWorkspace` 是 LaunchServices/XPC 调用，不产生子进程，因此合规：

```objc
NSWorkspaceOpenConfiguration *cfg = [NSWorkspaceOpenConfiguration configuration];
cfg.createsNewApplicationInstance = YES;   // 不加这条只是把运行中的自己激活一下，等于没重启
[[NSWorkspace sharedWorkspace] openApplicationAtURL:[[NSBundle mainBundle] bundleURL]
                                      configuration:cfg
                                  completionHandler:^(NSRunningApplication *app, NSError *err) {
    dispatch_async(dispatch_get_main_queue(), ^{ [NSApp terminate:nil]; });
}];
```

⚠️ 用 `System Events` 的 `click button "…” of window 1` 点这个弹窗的按钮时会报
**-1728（不能获得该按钮）**，但点击其实**已经生效**：按钮在 `runModal` 返回后就被销毁，
System Events 只是在回读元素引用时报错。别据此判断「重启没成功」——用
`ps -o etime=` 看进程存活时长才是可靠证据（实测重启后 etime 归零）。

### 坑点 32：菜单动作名写成字符串就失去了编译期检查

列表右键菜单单独成文件（`Z7ListContextMenu.m`）以便被 `objc-test` 链接，代价是它不能
`#import main.m`，动作名只能写成字符串：

```objc
NSString * const Z7ListSelPreview = @"doPreview:";   // 拼错？编译器不会说话
```

拼错的后果是「右键点那一项没反应」——而本机合成鼠标事件无效（坑点 8 一带），界面上
连复现都做不到。因此加了两道：

- `objc-test` 断言菜单的**标题序列与动作名序列**，两者一起钉住；
- `build_app.sh` 做一次跨文件核对：从 `Z7ListContextMenu.m` 抽出所有 `Z7ListSel*` 常量值，
  与 `main.m` 里 `- (…)name:` 的方法名集合比对，**有引用没有实现就构建失败**。
  「全选」是有意的例外（target 留空，交响应链给 `NSOutlineView`），在白名单里。

负向测试是本项目对门禁的一贯要求：把 `doPreview:` 改成 `doPreveiw:`，构建必须红。

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

### 外部压缩库链到哪里（容易搞混）

`lib7z.dylib` 是**上游 Format7zF Bundle** 的产物，**不含桥接层**；桥接层
（`lib7zbridge.a` + `lib7zbridgeobjc.a`，也就是 `SevenZipEngine.*`、
`Z7ExtCodec.*`、`Z7IsoWriter.*`、`Z7DmgWriter.*`）链进的是**应用主程序**
`7-Zip.app/Contents/MacOS/7-Zip`。

因此 zstd / lz4 / brotli 的静态库由 `build_app.sh` 与各测试脚本通过
`EXT_CODEC_LIBS` 链入，**不在 `lib7z.dylib` 里**。想核对是否真的链上了，别去看
dylib，要看主程序：

```bash
nm -gU dist/7-Zip.app/Contents/MacOS/7-Zip | grep -cE 'ZSTD_|LZ4_'   # 应为几百
nm -u  dist/7-Zip.app/Contents/MacOS/7-Zip | grep -cE 'ZSTD_|LZ4_'   # 应为 0
otool -L dist/7-Zip.app/Contents/MacOS/7-Zip                          # 不应出现 libzstd 等
```

`dist/engine/ext_codecs.sh` 探测 `/opt/homebrew/lib` 与 `/usr/local/lib` 下的
静态库，输出 `EXT_CODEC_DEFS` / `EXT_CODEC_INCS` / `EXT_CODEC_LIBS`。**缺库就把
对应格式编译出去**（`Z7_HAVE_*` 未定义），构建照常成功——CI 与本机无 Homebrew
的环境都靠这个降级路径过门禁。

### 链 Homebrew 静态库会带来「minos 不一致」警告（已知取舍）

Homebrew 的 `/opt/homebrew/lib/libzstd.a` 等是**针对较新 macOS 构建**的，链接时
会刷一屏（本机与 CI 都如此）：

```
ld: warning: object file (/opt/homebrew/lib/libzstd.a[3](entropy_common.c.o))
  was built for newer 'macOS' version (14.0) than being linked (11.0)
```

**这是警告不是错误，可以接受**：最终产物的 minos 仍由 `-mmacosx-version-min`
决定（应用 11.0、扩展 12.0），而 zstd / lz4 / brotli 只用到 libc 里最古老的一批
符号（`malloc` / `memcpy` / …），不依赖新版系统 API，因此在 11.0 上实际可用。

但它意味着「macOS 11.0 起可用」这个声明**只在功能层面成立，不再由工具链逐符号
保证**。若将来升级到真正依赖新系统 API 的库版本，必须改为自行以正确的
deployment target 编译这三个库（或把其源码 vendored 进构建），不能继续链
Homebrew 的产物。

⚠️ **不要为了清爽在构建脚本里加 `-Wl,-w` 之类把这类警告整体静音**——它是这里
唯一的提示。要过滤也只该在阅读日志时过滤，不该在构建时过滤。
（本项目的构建脚本没有做任何过滤，CI 日志里能看到原文。）

### 外部压缩库链到哪里（容易搞混）

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
| 本地化随包 | 同上 | 两种语言的 `Localizable.strings` 均存在，英文表与源文件逐字节一致，`CFBundleDevelopmentRegion = zh-Hans` |
| 帮助书可查找 | 同上（内部走 `osascript -l JavaScript` + `NSBundle`） | 帮助书能按本地化规则被找到；每语言均有 `index.html` 与 `hiutil` 生成的索引，且与 `HPDBookIndexPath` 声明一致 |
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
make test        # 桥接层验收，对照官方 7zz 逐项比对（158 个用例，共 20 节）
make objc-test   # ObjC 适配层验收（App 实际调用的那一层，95 个用例）
make appcheck    # 应用包验收（含真实启动与进程模型检查，42 个用例）
make verify      # 离线校验：安装/卸载脚本逻辑 + Homebrew 公式一致性
make check       # verify + 产物校验和 + DMG 完整性 + 应用签名
make tarball     # Homebrew 分发包（可复现，见上）
```

> `make appcheck` 里有一条断言用 `osascript -l JavaScript` 走 `NSBundle` 查帮助书
> （见坑点 27），因此需要能加载 Foundation 的环境；应用本身也需要图形会话才能启动。

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
  也就无法派生辅助进程。当前实现因此让扩展**直接链接 `lib7z.dylib`、在扩展
  自己的进程内列举条目**（`ql-src/EngineListing.mm`），不依赖任何子进程；引擎
  拒绝该文件时才回退到内置的纯 C 解析器（`ql-src/ArchiveReader.c`）。好处是
  ad-hoc 签名的分发版本同样能正常预览，且对**引擎支持的所有格式**都给出完整
  列表（2026-09-24 实测确认，见上文"为什么应用包里一份 7zz 都没有"）。
- **DMG 创建的 `hdiutil` 是唯一子进程例外**，理由与断言放宽方式见「坑点 17」。
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
