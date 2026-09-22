# 7-Zip macOS · 文件列表与整体 UI 易用性优化建议（参照 Bandizip）

> 目标：消除「文件列表不像 macOS、UI 太古早」的观感，向 Bandizip 的 mac 版交互范式靠拢。
> 依据：当前实现 `dist/app-src/main.m`（约 2800 行，单 `Z7ViewController`），
> 实测截图（浅色/深色/日志抽屉/空状态均已验证）。
> 约定：本机 AppKit 存在「NSScrollView/NSOutlineView 作为 `drop` 直接子视图由
> Auto Layout 摆放时不绘制」的坑（见 `BUILD.md` 坑点 7），所有新增列表/侧栏
> 必须用显式 frame（参照现有 `layoutContentFrames`），不要交给约束。

---

## 一、现状诊断（为什么「古早」）

| 维度 | 现状（main.m 实测） | 给人的感觉 |
|---|---|---|
| 列数 | 默认 8 列全显示：名称/大小/压缩后/压缩率/修改时间/CRC/方法/属性（L1199–1208） | CRC、方法、属性是开发工具味，Finder 从不默认显示 |
| 图标 | 用通用 SF Symbols 模板灰图标 `folder/doc/link`（L2371–2375），无真实文件类型 | 一眼「自己写的工具」，不是原生 |
| 时间格式 | `yyyy-MM-dd HH:mm:ss`（19 字符含秒，L56–66） | 冗长、报表风 |
| 行高 | `rowHeight = 22`（L1188），偏挤 | 拥挤 |
| 侧栏 | **无**；`NSOutlineView` 独占整个内容区 | 与 Finder / Bandizip 结构差最大 |
| 预览 | 仅空格触发系统 Quick Look 面板，无内嵌预览 | 缺「现代归档工具」观感 |
| 工具栏 | icon-only 八键平等（L1502–1527） | 主操作不突出 |
| 路径栏 | 无 | 进多层目录后易迷失 |

**结论：最像「古早」的三处是 —— ① 默认展示 CRC/方法/属性 等技术列；
② 全灰通用图标而非真实文件类型图标；③ 完全没有导航侧栏。** 这三处
优先级最高、且前两项改造成本极低。

---

## 二、修改意见（按感知影响排序）

### P0 · 文件列表本身（低成本、高感知，建议先做）

#### P0.1 精简默认列，技术列移入「显示列」菜单  ⭐最高优先
- **现状**：8 列默认全开（L1199–1208）。
- **Bandizip**：默认只 Name / Size / Type / Modified；CRC、压缩方法等藏在
  列头右键或「查看」菜单里按需勾选。
- **改法**：
  1. 默认列改为 **名称（图标+名）/ 大小（右对齐）/ 修改时间 / 类型**（或保留「压缩后」）。
  2. 压缩率 / 压缩后 / CRC / 方法 / 属性 → 改为可隐藏：给每个 `NSTableColumn`
     设置 `menu`（列头右键上下文菜单），勾选项控制 `isHidden`。这是 macOS 标准做法。
  3. `allowsColumnReordering=YES` 已开（L1185），保留即可拖拽排序。
- **收益**：单列 CRC/方法直接拉低「古早感」，文件列表立即变干净。
- **风险**：低。仅列显隐 + 一个菜单，不改布局结构。

#### P0.2 真实文件类型图标（最关键的一眼 native 感）  ⭐⭐
- **现状**：`Symbol(n.isSymLink?@"link":(n.isDirectory?@"folder":@"doc"))`
  全部模板灰图标（L2371–2375）。
- **Bandizip**：每个文件显示 Finder 同款彩色图标（图片=图片缩略、代码=代码图标…）。
- **改法**：用 `[[NSWorkspace sharedWorkspace] iconForFileType:ext]`
  （或 `iconForContentTypes:`，macOS 11+）取系统图标；目录用系统 folder 图标。
  **按扩展名缓存**（`NSDictionary<NSString*,NSImage*>`），避免每行重建。
  - L2371–2375 替换为：取 `n` 的扩展名 → 查缓存 → 命中则复用，未命中则
    `iconForFileType:` 并存入缓存；目录走 `[[NSWorkspace sharedWorkspace] iconForFileType:NSFileTypeForHFSTypeCode('fold')]` 或通用 folder。
  - 图标位 16–18pt，与 12pt 正文视觉重量匹配（现有 16×16 即可）。
- **收益**：这一项单独就能让列表从「开发工具」变「macOS 原生」。
- **风险**：低。`NSWorkspace` 在最低部署目标 macOS 11 上可用。

#### P0.3 时间列更克制
- **现状**：`yyyy-MM-dd HH:mm:ss`（L56–66）。
- **改法**：默认 `yyyy-MM-dd HH:mm`（去秒）；或近一年用 `M月d日 HH:mm`（参照
  Finder 相对格式）。完整秒可留在「详细信息」列。
- **收益**：列宽可从 160 收窄到 ~130，列表更透气。

#### P0.4 行高与选择态
- **现状**：`rowHeight = 22`（L1188），`usesAlternatingRowBackgroundColors = YES`
  但斑马纹也铺在空白尾行（已知问题）。
- **改法**：`rowHeight` 提到 **24–26**；`selectionHighlightStyle =
  NSTableViewSelectionHighlightStyleRegular`（系统强调色高亮）；斑马纹仅真实行
  （参照 `BUILD.md` 末尾遗留项：用 `NSTableViewStylePlain` + 控制尾行，或仅对
  有内容的行绘制）。
- **收益**：呼吸感 + 原生选中观感。

### P1 · 增加导航侧边栏（source list）—— 对标 Bandizip 最大结构差异

- **现状**：无侧栏，`NSOutlineView` 独占内容区。
- **Bandizip / Finder**：左侧 source list 显示归档内文件夹层级，右侧是当前
  文件夹的文件列表（双击进入）。
- **改法（两选一）**：
  - **方案 A（推荐，最像 Bandizip）**：`NSSplitViewController` 三栏 →
    `[侧栏文件夹树 | 文件列表 | 可选预览]`。侧栏用 `NSOutlineViewStyleSourceList`
    + `NSVisualEffectView(material = sidebar)` 玻璃材质；文件列表改为「当前选中
    文件夹的子项」扁平展示（双击文件夹进入），由现有 `Z7Node` 路径树直接驱动
    （`buildTree` 已从 `allItems` 重建层级，可复用）。
  - **方案 B（低风险）**：保留现有可展开树，仅在左侧加一条「顶层文件夹」source
    list + 顶部面包屑路径栏（path bar），点击即在现有树里展开/定位。
  - ⚠️ **本机约束（坑点 7）**：`NSSplitViewController` 内部 scroll 也可能触发
    不绘制坑。更稳妥的是**手动分栏 + 显式 frame**（参照现有 `layoutContentFrames`
    做法），或先在临时变体里验证再合入。
- **收益**：结构上一眼「macOS 文件管理工具」，导航大归档不再靠手风琴展开。

### P2 · 右侧预览窗格（toggle）

- **现状**：仅空格触发系统 Quick Look 面板（L2528+），无内嵌预览。
- **Bandizip**：可切换的右侧预览区，选图片/文本即时显示。
- **改法**：在 `NSSplitViewController` 增加第三栏（默认隐藏，工具栏「预览」
  按钮 ⌘P 切换），内嵌 `QLPreviewView`（临时解包选中项 → 喂给 QLPreviewView），
  或 `NSImageView` / `WKWebView` 处理图片/文本。复用现有 `previewURL` 逻辑
  （已经会解包到临时目录，L2503 附近）。
- **收益**：「现代归档工具」观感的关键增量。

### P3 · 工具栏与交互打磨

- **主操作突出**：把「解压到…」做成醒目主按钮（Bandizip 把 Extract 放最前且
  带标签/强调）。当前 icon-only 八键平等（L1502–1527）。建议 Extract / 新建
  用带文字的分段或强调样式，其余保持图标。
- **列头右键菜单**：显示/隐藏列（见 P0.1）。
- **双击行为**：文件双击 = Quick Look 预览（非展开）；文件夹双击 = 进入/展开。
  核对当前双击是否仅展开。
- **右键上下文菜单**：解压 / 预览 / 打开外部 / 复制路径 / 属性（§6 已有菜单，
  核对是否含「预览」「复制路径」）。
- **路径栏（path bar）**：工具栏下方或状态栏上方加一条，显示
  「归档名 ▸ 当前文件夹」，可点击跳转（对应 P1 方案 B）。

### P4 · 视觉材质与现代感

- 侧栏/预览栏包 `NSVisualEffectView`（`NSVisualEffectMaterialSidebar` /
  `ContentBackground`），获得系统玻璃质感。（注：状态栏刻意不用玻璃是规避本机
  透壁纸 bug，L698–705；侧栏在内容区可保留玻璃。）
- 窗口已 `NSWindowToolbarStyleUnified`；可进一步 `titlebarAppearsTransparent` +
  内容延伸到工具栏下，header 走 vibrancy。
- 选中/强调全部走 `controlAccentColor`（已做）。
- macOS 26 的圆角/分隔线：分隔线 1pt 已用；列表区圆角可加（需配合显式 frame 防坑）。

---

## 三、落地节奏建议

| 批次 | 内容 | 工期感 | 风险 |
|---|---|---|---|
| **第一批（消除古早感）** | P0.1 列精简 + P0.2 真实图标 + P0.3 时间格式 + P0.4 行高 | 半天 | 低，不改布局结构 |
| **第二批（结构改造）** | P1 侧栏 + P3 路径栏/双击/右键 | 1–2 天 | 中，触碰布局；注意坑点 7 |
| **第三批（增量体验）** | P2 预览窗格 + P4 材质 | 1 天 | 中，新增 scroll 防绘制坑 |

**建议先交付第一批**：它直接消除用户说的「古早/不像 macOS」，且零布局风险，
可立即 `make appcheck` + 浅色/深色截图验证后推送。

---

## 四、验证要点（防回归）

- 本机 Auto Layout draw 坑：所有新增 `NSScrollView`/`NSOutlineView` 必须用
  显式 frame（参照 `layoutContentFrames`），不要交给约束。
- 沿用既有门禁：`make test` / `make objc-test` / `make appcheck` / `make verify`
  / `make check` 全过。
- UI 验证沿用「按窗口 ID 直捕截图」（`/tmp/winid2` + `screencapture -l`），
  不要用 System Events 的 `AXPress`（本机会退化为坐标点击误触）。
- 浅色 + 深色各截一帧，确认语义色与玻璃材质无异常。

---

## 五、与既有约定的关系

- 内容区显式 frame 约定（坑点 7）**必须延续**到任何新增列表/侧栏，否则不绘制。
- `Z7Node` 路径树已就绪，P1 侧栏/Bandizip 范式可直接复用，无需改桥接层。
- 死代码清理（审计报告 P2–P4）与本优化正交：图标缓存、列显隐等新增逻辑应
  避免引入新的未用属性/方法。
