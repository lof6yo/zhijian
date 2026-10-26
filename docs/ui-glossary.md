# HMStart 界面要素命名约定

改界面时用**本文件的规范名**指代元素（例如「搜索框的圆角」「筛选条的选中项」
「页签栏的高度」）。规范名 → 代码位置 → 一句话定义，三者一一对应，避免同一句话
指到不同位置。

代码标识符用英文，口头/需求描述用中文；两者在下表成对出现。

定位写法：`文件名 › @Builder 名`，例如 `Index.ets › FloatingBar()`；
必要时补层级：`设置页 › 设置卡片 › 强调色色块 › 第 2 个（青）`。

---

## 0. 三条硬规则

1. **「标签」= tag，「页签」= tab。** 永远不要说「标签栏」来指底部那条 bar —
   「标签页」是 Tags 这个 tab 本身。底部那条叫**页签栏**。
2. **「卡片」= 网格里的笔记卡片（`NoteCard`）；「行」= 列表里的一条（标签行 /
   设置行 / 回收站行）。** 两者圆角、内边距、阴影都不同，说错了会改错文件。
3. **「标题」必须带限定词**：页面标题 / 卡片标题 / 编辑器标题。裸说「标题」不接受。

## 1. 层级模型

```
页面 Page
└── 区域 Region        标题区 / 搜索区 / 筛选区 / 列表区
    └── 控件 Control   搜索框 / 筛选条 / 笔记卡片 / 页签栏
        └── 部件 Part  卡片标题 / 归档徽标 / 页签项
```

另有三个横向概念：**层**（z 序）、**状态**（收起/选中…）、**令牌**（颜色/尺寸）。

---

## 2. 页面 Page

| 规范名 | 代码 | 定义 |
|---|---|---|
| 笔记页 | `Index.NotesPage()` | 第 1 个 tab，笔记卡片网格 |
| 标签页 | `Index.TagsPage()` | 第 2 个 tab，标签列表 |
| 设置页 | `Index.SettingsPage()` | 第 3 个 tab，设置列表 |
| 阅读页 | `ReaderPage.ets` | 打开笔记的页面（NavDestination）：默认渲染，点正文就地编辑 |
| 回收站页 | `TrashPage.ets` | 已删笔记列表（NavDestination） |
| WebDAV 页 | `WebDavPage.ets` | 同步设置（NavDestination） |

---

## 3. 区域 Region

| 规范名 | 代码 | 定义 |
|---|---|---|
| 背景层 | `Index.PageBackdrop()` | 全屏底色 / 渐变 / 光晕，三个 tab 共用 |
| 标题栏 | HDS `titleBar()`（`titleBarOptions()`） | 只装一行：页面标题 + 两个圆形玻璃按钮，由 `HdsNavigation` 拥有（MINI 模式） |
| 标题行 | `Index.TitleRow()` | 标题栏内唯一的 Row：页面标题（或展开后的搜索框）+ 搜索按钮 + 新建按钮 |
| 页头 | `Index.NotesHeader()` | 只有一行筛选条 / 排序条，通栏固定，**不含**页面标题、**不含**搜索框 |
| 筛选区 | 页头 `ChipGroup(0)` | 只含筛选项（全部 / 已归档 / 收藏） |
| 排序区 | 页头 `ChipGroup(10)` | 只含排序项（最近修改 / 按标题 / 按创建），与筛选条同一行 |
| 列表区 | `WaterFlow` / `List` | 可滚动内容 |
| 页签栏 | HDS `HdsTabs` 的 `TabBar` | 底部悬浮胶囊，内容从其下方滚过 |

> 标题栏使用 `HdsNavigationTitleMode.MINI`：FULL 会在 `stackBuilder` 行**下方**
> 再留一条大标题带（实测标题栏 117…453 px，行在 117…285、标题在 316…421），
> 页面标题和右侧按钮就分成两行了，与参考图不符。
> MINI 把标题栏压到单行 56 vp，且 `content.title` 留空时整行交给 `stackBuilder`；
> MINI 还会注入自己的返回按钮（实测 x 48…168，正好压住标题），所以根节点必须
> `.hideBackButton(true)`。
>
> 标题栏在页面内容之上绘制（`NavBarContent` 与标题栏同源），因此每个 tab 的根节点
> 都用 `TITLE_BAR_CLEARANCE`（实测 96 vp）的上内边距让出标题栏高度。
> 注意原点：`ignoreLayoutSafeArea` 下这个内边距从**窗口 y = 0** 起算，
> 所以它是标题栏下边缘的绝对高度，不是相对内容顶部的差值。

---

## 4. 控件 Control —— 页头

| 规范名 | 代码 | 定义 |
|---|---|---|
| 页面标题 | `Index.TitleRow()` 的 `Text(tabTitle())` | 标题行左端，随当前页签变化（笔记 / 标签 / 设置） |
| 搜索框 | `Index.SearchField()` | 单行输入，占位「搜索标题、正文、标签」，`id = notesSearchInput`；**只在搜索按钮被点开时出现**，不常驻 |
| 筛选条 | `Index.ChipGroup(0)` 的 Row | 装着三个筛选项的胶囊容器 |
| 筛选项 | `Index.FilterChip(label, mode)` | 全部 / 已归档 / 收藏，`layoutWeight(1)` 三等分 |
| 排序条 | `Index.ChipGroup(10)` 的 Row | 装着三个排序项的胶囊容器，样式与筛选条完全一致，与筛选条同一行 |
| 排序项 | `Index.FilterChip(label, mode)`，`mode ≥ 10` | 最近修改 / 按标题 / 按创建，`mode - 10` 即排序下标 |
| 搜索按钮 | `Index.TitleRow()` 左钮 | 圆形玻璃（`glass_tint` + `COMPONENT_THIN` 模糊 + 发丝边），`sys.symbol.magnifyingglass`；点开后**原地**展开为搜索框 |
| 新建按钮 | `Index.TitleRow()` 右钮 | 圆形玻璃，同款材质，`sys.symbol.plus`；**唯一**的新建入口，不用强调色 |

> **两个「三选一」控件不要混称**：页头的叫**筛选条 / 筛选项**和**排序条 / 排序项**，
> 选中态都是**淡底强调色**（`accentChipColor` 底 + 强调色文字）；设置页的叫
> **分段控件 / 分段项**，选中态是**实心强调色**。改错一个会连带另一个。
> 「筛选条」也不要叫「切换栏目」「tab」「顶部分段」。
>
> 筛选条和排序条**共用一行**（各自 `layoutWeight(1)`），叠成两行会白占一条带、
> 把列表往下推。
>
> `ChipGroup(base)` 用同一个 `base` 生成整条：`base = 0` 是筛选条，`base = 10` 是排序条。
> `FilterChip` 用 `mode < 10` 判断自己属于哪一条，所以新增一条分段条时，`base`
> 必须是 10 的倍数，否则会串到前一条。
>
> **不要常驻搜索框**：搜索按钮和常驻搜索框是同一个操作的两个入口，会重复。
> 点搜索按钮 → `searchExpanded` 置真 → 标题行原地换成 `SearchField()`；
> 点搜索框右侧的 × → 清空 `query` 并收起，标题回来。

---

## 5. 控件 Control —— 笔记卡片

| 规范名 | 代码 | 定义 |
|---|---|---|
| 笔记卡片 | `NoteCard` | 网格单元，2 列，圆角 26，`sys.color.ohos_id_color_card_bg` |
| 卡片标题 | `Text(title)` | 最多 2 行 |
| 卡片摘要 | `Text(excerpt)` | 最多 2 行，13sp |
| 卡片标签 | 卡片内 `ForEach(tags)` | 最多 3 个，chip 样式 |
| 卡片时间 | `Text(relativeTime)` | 「3 小时前」 |
| 归档徽标 | `Text('已归档')` | 强调色淡底小胶囊；只在「已归档」列表里出现 |
| 收藏徽标 | `Text('★')` | 金色星号 |
| 卡片菜单 | `NoteCard.CardMenu()` | 长按弹出：归档/收藏/标签…/删除；这里的归档会确认（划动不确认） |
| 空状态 | `Index.EmptyState()` | 按筛选项分档：「还没有笔记」/「还没有归档的笔记」/「还没有收藏的笔记」 |

> 新建按钮**不在**这里：它已经迁到标题栏的**标题行**（`Index.TitleRow()`），页面里不再有 FAB。
> 网格单元宽度由 `columnWidth()` 按屏幕实宽 / 密度 / 两列算出并显式传给
> `FlowItem` 的子节点 —— `WaterFlow` 会拿整个流水容器的宽度去测量 `FlowItem` 的
> 子节点，不显式限宽时宽内容会横向冲进相邻列。

---

## 6. 控件 Control —— 页签栏

| 规范名 | 代码 | 定义 |
|---|---|---|
| 页签栏 | HDS `HdsTabs` 的 `TabBar`（`floatingBarStyle()`） | 底部悬浮胶囊，内容从其下方滚过 |
| 页签项 | `.tabBar(this.TabItem(...))` | 笔记 / 标签 / 设置，`layoutWeight(1)` |
| 页签图标 | 页签项内 `SymbolGlyph` | `sys.symbol.*`，18sp |
| 页签文字 | 页签项内 `Text` | 10sp |

> 页签栏不再是手绘的 `FloatingBar`：外观由 HDS `BottomTabBarStyle` +
> `barFloatingStyle()` 决定（`barWidth` / `barBottomMargin` / `gradientMask` /
> `systemMaterialEffect`）。`HdsTabs` 带 `barOverlap(true)`，所以卡片会从胶囊
> 下方滚过去，列表靠 `contentEndOffset` 让出底部空间。
>
> 页签**选中色跟随用户的强调色设置**，不是固定的
> `sys.color.ohos_id_color_activated`（用户已确认这一取舍）。

---

## 7. 控件 Control —— 设置页 / 标签页

| 规范名 | 代码 | 定义 |
|---|---|---|
| 设置行 | `Index.SettingRow(title, value)` | WebDAV / 导入导出 / 回收站 / 关于，共 4 行，圆角 16 |
| 设置卡片 | `ListItem` 里 `glass_bg` 的 Column | 外观合并卡（4 行）、字号行距卡（2 滑块），无独立 Builder |
| 分段控件 | 设置行内 `Row` + `SegmentButton` ×3 | 装着三个分段项，外层 `padding(3)` 圆角 14 |
| 分段项 | `Index.SegmentButton(label, value, kind)` | `kind` 取 `SEG_THEME` / `SEG_BACKGROUND` / `SEG_GLASS`，实心强调色选中 |
| 沉浸光感挡位 | 外观卡第 3 行的分段控件 | 自适应 / 高 / 中 / 低，写 `SettingsStore.glassLevel`；副标题显示本机算力等级 |
| 强调色色块 | `Index.AccentSwatch(item, index)` | 蓝 / 青 / 橙，选中放大到 30 并加细环 |
| 字号滑块 | 编辑器字号下方的 `Slider` | 14–22 px，步长 1 |
| 行距滑块 | 行距下方的 `Slider` | 1.40–2.20 倍，步长 5（值域 140–220） |
| 标签行 | `TagsPage` 里的 `ListItem` | `# 标签名` + 计数，点击经 `filterByTag()` 回笔记页并展开搜索框显示该标签 |

---

## 8. 控件 Control —— 阅读页 / 回收站页

| 规范名 | 代码 | 定义 |
|---|---|---|
| 阅读页头 | `ReaderPage` 顶部 Row | 高 56，不透明 `page_bg`，不加状态栏内边距 |
| 返回按钮 | `Button('‹')` | 阅读页与回收站各一个 |
| 笔记标题 | 页头中间 `Text` | 跟随 H1 |
| 正在编辑条 | `Row`（`正在编辑 · 标题/引用/…`） | 只在该块处于编辑态时出现，右端是 删除 / 完成 |
| 块编辑器 | `TextArea`（`LiveBlockEditor`） | 源码在上，`预览效果` 在下；等宽字体 |
| 整篇编辑器 | `TextArea`（`WholeDocEditor`） | 「简单」编辑体验：全屏一个 Markdown 字段 |
| 格式按钮条 | `FormatBar` | 标题/粗体/斜体/列表/待办/引用/表格/代码，默认关闭 |
| 回收站行 | `TrashPage` 里的 `ListItem` | 标题 + 删除时间 + 恢复/删除 |
| 清空按钮 | 页头右端 `Text('清空')` | 危险色 |

---

## 9. 状态 State

| 规范名 | 代码 | 定义 |
|---|---|---|
| 收起 | HDS 滚动联动 | 内容上滑时标题栏收为紧凑态并出现渐变模糊 |
| 展开 | `barCollapsed = false` | 页签栏复位 |
| 选中 | `selectedTab` / `filterMode` / `sortMode` / `accentMode` | 下标数字 |
| 已滚动 | `ScrollEffectType.IMMERSIVE_GRADIENT_BLUR` | 标题栏模糊出现的条件，由 `bindToScrollable` 驱动 |
| 深色 | `activeDark()` | 跟随系统解析后的最终值 |

---

## 10. 视觉令牌 Token

| 规范名 | 资源名 | 用途 |
|---|---|---|
| 玻璃底 | `glass_bg` | 静态玻璃（设置卡片），无模糊 |
| 玻璃浮层 | `glass_tint` | 悬浮玻璃的底色，交给 `glassEffect()` |
| 玻璃高光 | `glass_hi` | 镜面高光，玻璃上缘那道反光 |
| 玻璃描边 | `glass_border` | 发丝边，粗细随 `glassLevel`；**仅手绘玻璃用**，官方材质会自动清掉 `borderWidth` |
| 玻璃阴影 | `glass_shadow` | 已降到 ~10%/30%，不要再加浓 |
| 玻璃挡位 | `glassLevel` = 0/1/2/3 | 自适应 / 高 / 中 / 低；设置 › 外观 › 沉浸光感挡位 |
| 沉浸材质 | `uiMaterial.ImmersiveMaterial` | 官方材质，只用于标题行内的圆按钮与搜索框（`stackBuilder` 内才生效） |
| 页面底色 | `page_bg` | 纯色背景 / 编辑器页 |
| 页面渐变 | `page_grad_top/mid/bottom` | 渐变背景三停 |
| 光晕 | `glow_blue/purple/cyan` | 光感背景装饰，必须 `hitTestBehavior(None)` |
| 侧内缩 | `SIDE_INSET` = 16 | 标题行/筛选条/页签栏统一左右缩进 |
| 标题栏避让 | `TITLE_BAR_CLEARANCE` = 96 | 各 tab 根节点的上内边距，实测 MINI 标题栏下边缘（285 px / 3）；从窗口 y = 0 起算 |
| 页签栏高 | `BAR_HEIGHT` = 56 | |
| 页签栏底距 | `BAR_BOTTOM_MARGIN` = 32 | |
| 卡片底 | `sys.color.ohos_id_color_card_bg` | 笔记卡片 / 设置行，随系统明暗解析 |
| 交互反馈 | `sys.color.ohos_id_color_click_effect` / `ohos_id_color_hover` | 系统按压 / 悬停底色 |

> **旧名作废**：`glass_float`（85% 不透明）不再用于新代码，它的存在是为了掩盖
> 缺失的模糊，是页签栏「像一块板」的原因。`glass_bg` 也不再用于笔记卡片 ——
> 卡片改用系统卡片色，由平台保证明暗两套值。
>
> **「沉浸光感挡位」是用户可调策略，不是一个固定强度。** 官方模型有两条独立的轴，
> 不能合并：**算力等级**（`uiMaterial.MaterialLevel` = 高/中/低）由设备决定，只能
> 通过 `getGlobalMaterialLevel()` 读取，文档明确「不支持设置」；**厚度**
> （`uiMaterial.ImmersiveStyle`）才是设计上可调的。`hdsMaterial.MaterialLevel` 可以
> 强设算力等级，但文档警告低算力设备上强设 EXQUISITE/GENTLE「可能造成卡顿和发热」，
> 并推荐 `ADAPTIVE`。所以 `glassLevel` 是**策略**：`GEAR_ADAPTIVE`（默认，交给系统）/
> `GEAR_HIGH` / `GEAR_MEDIUM` / `GEAR_LOW`，由 `materialLevel()` 翻译成官方枚举。
> 挡位改动同时作用于四处：手绘玻璃的模糊（`glassEffect()`）、镜面高光
> （`glassSheenStop()`）、描边粗细（`glassRimWidth()`）和 HDS 页签栏的材质等级
> （`materialLevel()`）。改挡位只重绘，不重建任何组件。
>
> **沉浸材质（`systemMaterial`）有硬性生效范围**：只在 `Navigation` /
> `NavDestination` 标题栏、`barPosition(End)` 的横向底部页签栏，以及文档列出的弹窗
> / Slider / Toggle / Select 生效，「在其他区域中设置沉浸光感效果不生效」。筛选条与
> 排序条在内容区，永远用不了，这正是整个手绘玻璃家族共用 `glassEffect()` 的原因。
> 已实测：内容区的胶囊加 `.backgroundColor(Color.Red).systemMaterial(...)` 后红色
> 完整保留，证明材质从未生效。
>
> **标题行里的圆按钮和搜索框用的是真材质。** 它们在 `stackBuilder` 内，属于生效
> 范围，走 `.systemMaterial(immersiveMaterial())`；`immersiveSupported` 为假时回退到
> 手绘三层玻璃。三个连带约束：`backgroundColor` 必须是 `Color.Transparent`、
> **绝对不要设 `border`**、圆形靠 `clipShape(CircleShape)` 而不是 `borderRadius`。
>
> **整个 shell 只有一张背景。** `build()` 是 `PageBackdrop()` + `Navigation` 的
> `Stack`，`HdsShell`/`PlainShell` 自己不再画背景。以前每个 `TabContent` 各画一份，
> 横向滑动时两份渐变互相滑过、边界在屏幕中间相接，这就是用户看到的拼接痕迹。
> 不要在 `TabContent` 里重新加 `PageBackdrop()`。

---

## 11. 易混词速查（错 → 对）

| 不要这样说 | 这样说 |
|---|---|
| tab 栏 / 底部导航栏 / 导航栏 / 标签栏 | **页签栏** |
| 切换栏目 / 那个切换条 / 顶部分段 | **筛选条**（在页头） |
| 搜索栏 | **搜索框** |
| 卡片 / 列表项（混用） | 网格里叫**笔记卡片**，列表里叫**行** |
| 底部那个按钮 / 加号 | **新建按钮**（FAB） |
| 标题（不加限定） | **页面标题** / **卡片标题** / **编辑器标题** |
| 弹窗 | **对话框**（`showAlertDialog`）/ **操作面板**（导入导出） |
| 背景色 | 分**背景层**、**玻璃底**、**页面底色** |
| 阴影太重 | 说清是 `glass_shadow` 还是强调色光晕 |
| 上面那三个按钮（全部/已归档/收藏） | **筛选条**里的**筛选项** |
| 设置页的筛选条 | **分段控件**（`SegmentButton` 所在的那个 Row） |
| 顶部标题栏 / header / 头部 | **标题栏**（页面标题 + 两个圆形按钮）/ 下方的叫**页头**（页头 = 筛选区 + 排序区，同一行） |
| 白框 / 灰框 / 气泡 | **玻璃底**（`glass_bg`）或**玻璃浮层**（`glass_tint`） |
| 圆角 26 那个卡片 / 大卡片 | **笔记卡片**；设置页的叫**设置卡片**（圆角 20） |
| 上面那条排序 | **排序条**里的**排序项**（与筛选条同一行、同款） |
| 右上角两个圆圈 | **标题行**里的**搜索按钮** / **新建按钮** |

---

## 12. 需求表述示例

- ✅「页签栏的玻璃再透一点，阴影再淡一点」
- ✅「筛选条的选中项不要实心强调色，改成淡底」
- ✅「筛选条和排序条压成一行」
- ✅「排序条换成和筛选条一样的圆角高度」
- ✅「新建按钮和搜索按钮都用玻璃质感，不要强调色」
- ✅「点搜索按钮，圆圈原地展开成圆角搜索框」
- ✅「笔记卡片标题改成最多 3 行」
- ❌「tab 栏和上面的切换栏目宽度对不上，阴影很突兀」
  → 「页签栏和筛选条的左边缘对不齐，`glass_shadow` 太重」

---

## 13. 定位约定

默认按**页面 + 区域 + 控件**三级定位，必要时补部件：

```
笔记页 › 页头 › 筛选条 › 选中筛选项
笔记页 › 标题栏 › 标题行 › 新建按钮
设置页 › 设置卡片 › 强调色色块 › 第 2 个（青）
编辑器页 › 编辑器页头 › 保存状态
```

代码位置始终写 `文件名 › @Builder 名`，例如
`entry/src/main/ets/pages/Index.ets › TitleRow()`。

---

## 14. HDS 术语对照

界面骨架由 HDS（`@kit.UIDesignKit`）提供，读代码时用下面的映射：

| 中文 | 代码 | 备注 |
|---|---|---|
| HDS 导航器 | `HdsNavigation` | 同时是路由容器（`navDestination(this.pageMap)`） |
| 标题栏 | `titleBar()` + `titleBarOptions()` | 单行（MINI 模式）：页面标题 + 两个圆形玻璃按钮 |
| 标题模式 | `HdsNavigationTitleMode.MINI` | 单行 56 vp；FULL 会在 `stackBuilder` 下方多留一条大标题带，标题与按钮分两行 |
| 标题行 | `stackBuilder` → `Index.TitleRow()` | 不设 `content.title`，整行由页面自绘 |
| 返回按钮 | `.hideBackButton(true)` | MINI 默认注入的返回按钮会压住标题（x 48…168），根节点必须关掉 |
| 滚动联动 | `bindToScrollable([scroller])` | 绑定当前 tab 的滚动器 |
| 渐变模糊 | `ScrollEffectType.IMMERSIVE_GRADIENT_BLUR` | 规范里写的 `GRADIENT_BLUR` 在本地 SDK 里不存在 |
| 光感材质 | `systemMaterialEffect` + `hdsMaterial` | `MaterialType.ADAPTIVE` / `MaterialLevel.ADAPTIVE` |
| HDS 页签 | `HdsTabs` + `HdsTabsController` | `bindScroller(index, scroller)` 给每个 tab 独立滚动位置 |
| 悬浮页签栏 | `barFloatingStyle()` | 只在 `HdsTabs` 上生效 |
| 降级壳 | `Index.PlainShell()` | `deviceInfo.sdkApiVersion < 23` 时使用 |

