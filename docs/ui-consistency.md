# 控件一致性规范

> 本文档与 `docs/ui-glossary.md` 配套使用：glossary 定义「叫什么」，本文档定义「长什么样、什么时候用」。

---

## 1. 圆角三档

| 常量 | 值 | 用途 |
|---|---|---|
| `RADIUS_CONTROL` | 12 vp | 按钮、输入框、行内动作（`TextAction`） |
| `RADIUS_PILL` | 14 vp | 28 vp 胶囊（筛选条、排序条、分段控件） |
| `RADIUS_SURFACE` | 不导出 | 第 17 档就是 `CARD_CORNER`（`services/SettingsStore.ets`），**故意不做成模块常量**：它按「卡片圆角」设置可变，是运行期值。笔记卡片、设置卡片、搜索提示条、回收站行、`AutoSyncGroup` 的状态条共用它 |

> 为什么只有三档：再细一档（8 / 10 / 12 / 14 / 16 / 20）会让「同一页上相邻控件圆角不同」变成常态，而用户看不出 12 与 14 的区别，只会觉得「没对齐」。三档足够区分「控件 / 胶囊 / 卡片」三个层级。

---

## 2. 字号五档

| 档位 | 字号 | 字重 | 用途 |
|---|---|---|---|
| 页头标题 | 16 | Medium | `PageHeader` 标题、WebDAV 页标题 |
| 卡片标题 | 15 | Medium | 笔记卡片标题、回收站行标题 |
| 正文 | 14 | Regular | 正文段落、编辑器源码、按钮标签 |
| 次要 | 12 | Regular | 副标题、时间戳、标签、行内动作 |
| 微 | 11 | Regular | 后缀文本（如 `zhijian/`）、状态提示 |

> 为什么 24 Bold 的回收站标题被废弃：`TrashPage.ets` 第 43–46 行用了 24 Bold，与整应用「16 Medium 页头」不一致，且 Bold 在深色模式下发光感过强，像系统弹窗而不是应用内页。

---

## 3. 四个控件的使用边界

### 3.1 `PageHeader` vs 悬浮玻璃钮

| 场景 | 用哪个 | 原因 |
|---|---|---|
| NavDestination 页面（回收站、WebDAV、设置子页） | `PageHeader` | 这些页有固定标题区，返回是「离开页面」而非「悬浮工具」 |
| 阅读页顶部 | `GlassButton`（`ReaderPage.ets` 现有） | 阅读页没有固定标题栏，返回钮浮在正文之上，与撤销/重做/AI 组成工具组 |

> 不要把 `PageHeader` 放进阅读页：它会占掉 56 vp 的固定高度，而阅读页的设计是「正文从顶边开始，按钮浮在滚动内容上」。

### 3.2 `ActionButton` vs `TextAction`

| 场景 | 用哪个 | 原因 |
|---|---|---|
| 页面底部成对操作（测试连接 / 立即同步） | `ActionButton` | 需要明确的按钮形状和足够大的热区（44 vp 高） |
| 列表行尾的小动作（恢复 / 删除） | `TextAction` | 行内、紧凑，不破坏列表行的横向节奏 |
| 危险操作（删除 / 清空 / 移除） | `TextAction(tone: TONE_DANGER)` | 危险色 + 文字形式，比实心红按钮更克制，避免「满屏红色」 |

> 为什么回收站的「恢复」不用 `ActionButton`：一行里塞两个 44 vp 高的按钮会让回收站行高超过 70 vp，看起来像卡片而不是行。

`TextAction` 的语义档位是**三档数字**（`TONE_PLAIN` / `TONE_ACCENT` / `TONE_DANGER`），不是
`danger: boolean` 加一个 `accent: boolean`：两个布尔就有优先级问题（同时为真画哪个），
而设置页的 `SegmentButton` 已经用 `kind` 遇到过同一个问题。三档各自对应一种**语义**而不是
三种颜色——回收站的「恢复」是正向动作，所以走 `TONE_ACCENT`（强调色文字 + `chip_bg` 底），
它原来就是这样，不是本轮新加的。`accentColor` 由调用方传，因为强调色是运行期 hex。

### 3.3 `EmptyState` vs 自建空提示

| 场景 | 用哪个 | 原因 |
|---|---|---|
| 列表/网格为空（笔记页、标签页、回收站页） | `EmptyState(fill: true)` | 占满剩余空间并垂直居中，底部留 160 vp 避让页签栏 / 键盘 |
| Sheet / 卡片内无数据 | `EmptyState(fill: false)` | 只做内容宽居中，不撑开父容器 |
| 表单字段还没有值（`TagSheet` 的「还没有标签」） | **一行 13 fp 灰字，不用 `EmptyState`** | 这是「这个字段还没填」，不是「这一片什么都没有」；一个 48 vp 图标会把它读成页面级空态 |

### 3.4 问题提示：`Toast` 与 `Dialogs`

| 场景 | 用哪个 | 原因 |
|---|---|---|
| 操作结果（已归档 / 已移入回收站 / 密钥保存失败） | `Toast.show(ui, msg)` | 不打断、不需要用户回应 |
| 不可逆动作前确认（删除 / 永久删除 / 清空 / 移除标签） | `Dialogs.danger(ui, title, msg, ok, fn)` | 确认键染危险色——这是它与「归档」唯一的视觉区别 |
| 可逆动作前确认（归档） | `Dialogs.accent(ui, title, msg, ok, okColor, fn)` | 确认键用强调色；`okColor` 由调用方给，因为强调色是运行期 hex |

> **为什么 toast 必须吞异常**：设备可能没有提示通道、窗口可能已在销毁，`showToast` 会抛。一次抛错不能把「已经写盘的删除」回滚成「失败」。
>
> **为什么确认框收成一个函数**：8 个 `showAlertDialog` 每一个都是同样的十二行，抄错一处（取消跑到右边、忘了危险色、忘了 `refresh`）都是用户按下去才发现的。

---

## 4. 旧实现 → 新控件 对照表

| 旧位置 | 行号 | 旧实现 | 替换为 |
|---|---|---|---|
| `TrashPage.ets` | 32–62 | 手写 `Button('‹')` + 24 Bold 标题 + 副标题 + `Text('清空')` | `PageHeader(title:'回收站', subtitle:'删除的笔记保留 30 天', trailing:'清空', trailingDanger:true, onBack:…)` |
| `TrashPage.ets` | 65–77 | 自建空状态 `Column`（无图标） | `EmptyState(icon: $r('sys.symbol.trash'), title:'回收站是空的', hint:'长按笔记卡片可以删除', fill: true)`（文案逐字沿用原句，不因为换控件就改写） |
| `TrashPage.ets` | 95 | `Text('恢复')` + 自填 padding/bg/radius | `TextAction(label:'恢复', tone: TONE_ACCENT, accentColor: this.accentColor, onTap:…)` |
| `TrashPage.ets` | 109 | `Text('删除')` + 自填 padding + danger 色 | `TextAction(label:'删除', tone: TONE_DANGER, filled: false, onTap:…)` |
| `WebDavPage.ets` | `Header()` | 手写 `Button('‹')` + 16 Medium 标题 + `Text('zhijian/')` | `PageHeader(title:'WebDAV 同步', note:'zhijian/', onBack:…)`（`zhijian/` 不是动作，走 `note` 不走 `trailing`） |
| `WebDavPage.ets` | 按钮行 | `Button('测试连接')` 高 44、圆角 0、字号 14 | `ActionButton(label:'测试连接', primary: false, accentColor:…, onTap:…).layoutWeight(1)` |
| `WebDavPage.ets` | 按钮行 | `Button('立即同步')` 高 44、圆角 0、强调色底 | `ActionButton(label:'立即同步', primary: true, accentColor:…, onTap:…).layoutWeight(1)` |
| `WebDavPage.ets` | `AutoSyncChip` | 选中态自填 `chip_bg` + 字重换 Medium | 强调色浅底（`accentChipColor`）+ 不换字重，与筛选条同一套「已选中」语言 |
| `WebDavPage.ets` | 五个 `TextInput` | `borderRadius(14)` | `borderRadius(RADIUS_CONTROL)`：输入框是控件档，不是胶囊档 |
| `Index.ets` | 3252 | 标签页一行 13 灰字 | `EmptyState(icon: $r('sys.symbol.label'), title:'还没有标签', hint:…, fill: true)` |
| `Index.ets` | 3192–3212 | `@Builder EmptyState()` 自建三段式 | 构建体换成 `components/ui/EmptyState`；`emptyIcon()/emptyTitle()/emptyHint()` 三个业务判断留在页面 |
| `WebDavPage.ets` | 502 | `promptAction.showToast({ message, duration: 1600 })` | `Toast.show(this.getUIContext(), message)` |
| `ReaderPage.ets` | 576, 584, 602, 901, 1111 | `this.getUIContext().getPromptAction().showToast({ message })` | `Toast.show(this.getUIContext(), message)` |
| `Index.ets` | 2092, 2244, 2248, 2259, 2271, 2289, 2294, 2661, 2694, 2721, 2734, 2742, 3366, 3402, 3410, 3413, 4282, 4338, 4347, 4475, 4484 | `this.getUIContext().getPromptAction().showToast({ message, duration: … })` | `Toast.show(this.getUIContext(), message)` |

---

## 5. 本轮不提取的控件

- `GlassButton`：阅读页专用，暂不提取（它与 `FLOAT_HIT` / `FLOAT_INSET` / `gate` 机制耦合过深，提取后参数列表会超过 6 个，反而难用）。
- `CircleAction`：HDS 标题行专用，暂不提取（它依赖 `Index.ets` 的 `immersiveSupported` / `glassEffect()` / `immersiveMaterial()` 等字段，提取需要把整套材质判断下沉，范围过大）。
- `AutoSyncChip`（`WebDavPage`）：仍是每个 chip 自己填底色的实现，没有迁到首页 / 标签页的**滑动指示器**（`ChipIndicator`）。两页的差别在于是否要「看得见指示器移动」：笔记页的筛选条是主界面常驻控件，位移本身在表达「从哪到哪」；WebDAV 页的两行 chip 是低频配置项，只在选中时亮一下即可。已统一的是**颜色语言**（强调色浅底 + 强调色字、不换字重、200 ms `FastOutSlowIn`），未统一的是**动效形式**——这是有意的差异，不是漏改。

## 6. 本轮发现但未统一的两处漂移

- **`Index.ets` 内部仍有 10/11/12/13/14/16 六种圆角**，其中 12 是三处输入框、14 是胶囊、17 是卡片（`cardCorner`）。这三档是有意的，剩下的 10/11/13/16 是历史残留：`TagPill` 的 16（药丸比胶囊大一圈）、`InsightOverlay` 的 17（已等于 `CARD_CORNER`，可以换常量）、`SegmentButton` 的 11（子项比胶囊小，包在 14 的胶囊里）。这些数字**各自有理由**，不是随手写的，所以本轮只把「新增控件」锁进三档，没有回去改存量。**例外是回收站那一行**：它的 16 没有任何理由（笔记卡片是 17），已换成 `CARD_CORNER`——同一页签栏下的卡片差 1 vp 正是这一节要消灭的那种漂移。
- **`Index.ets` 的 `EmptyState` 尾部留白从 120 改到 160**：`fill: true` 同时要避让页签栏和键盘工具条，120 在搜索无结果、键盘展开时会把「换个关键词试试」压在键盘边缘（实测被切掉约 6 px）。
