# 纸见 v1.0.3

一个「控件一致性」版本。这一版不新增功能，改的是**同一种控件在不同页有不同的样子**。

## 为什么值得单独发一版

回收站和 WebDAV 页各写了一遍页头，而且两遍不一样：返回都是 `Button('‹')`（一个
**文本字符**，字形、基线、左右留白都来自字体），标题却一个 24 Bold、一个 16 Medium。
空态有三种——「图标 + 标题 + 提示」的三段式、一行 13 灰字、两行文字——其中两处还是
同一页签栏下的并列页签。toast 有三种写法（`getPromptAction()`、直接
`import { promptAction }`、自带 try-catch），时长 1600 / 2000 / 无显式值三种。

用户看不出 12 vp 与 14 vp 的圆角差别，只会觉得「没对齐」。所以问题不是某一处写错了，
而是**没有一处说了算**。

## 共用控件层

| 控件 | 文件 | 边界 |
|---|---|---|
| `PageHeader` | `components/ui/PageHeader.ets` | NavDestination 页专用 |
| `EmptyState` | `components/ui/EmptyState.ets` | `fill` 是布局档位，不是视觉风格 |
| `ActionButton` / `TextAction` | `components/ui/ActionButton.ets` | 44 vp 成对按钮 / 行内小动作 |
| `Toast.show(ui, msg)` | `common/Toast.ets` | 全应用唯一的 toast 入口 |
| `Dialogs.danger` / `accent` | `common/Dialogs.ets` | 不可逆 / 可逆确认框 |
| `RADIUS_*` / `FONT_*` | `common/UiTokens.ets` | 圆角三档、字号五档 |

四条从实测里来的约束，写进了头注释：

- **`ActionButton` 必须自己声明 `width('100%')`。** `Button` 默认是内容宽，
  `.layoutWeight(1)` 拉宽的只是自定义组件的外壳——440 vp 屏上实测成 92 vp 的按钮，
  中间空出 350 px，读起来是两个小胶囊飘在一条空行里。
- **`TextAction` 用三档 `tone` 而不是 `danger` 布尔。** 两个布尔就有优先级问题；
  设置页的分段控件已经用 `kind` 遇到过同一个问题。
- **`Toast` 必须吞异常。** 设备没有提示通道时 `showToast` 会抛，而那次删除已经写盘了，
  不能因为提示失败变成「失败」。
- **`@Param` 不能用 ArkUI 保留名。** `ActionButton` 的可点开关叫 `isEnabled` 而不是
  `enabled`，否则与 `CustomComponent` 基类同名，静态检查直接报不可赋值。

## 逐页改动

**回收站**：手写页头 → `PageHeader`（24 Bold 标题没了）；自建空态 → `EmptyState`
（多了图标，三段各答一个问题）；行内「恢复 / 删除」→ `TextAction`；行卡片圆角
16 → `CARD_CORNER`（笔记卡片是 17，同一页签栏下差 1 vp 正是要消灭的那种漂移）。

**WebDAV 页**：`Header()` → `PageHeader`；两个裸 `Button`（圆角 0）→ `ActionButton`；
`promptAction.showToast` → `Toast`；五个输入框从 `borderRadius(14)` 改成控制档 12
（输入框不是胶囊）；自动同步的 chip 选中态换成强调色浅底 + 强调色字，且**不再换字重**
——Medium 与 Normal 的字宽不同，切档时居中的标签会横向抖一下，比底色变化更响。

**笔记页 / 标签页 / 设置页**：自建空态换成共用组件（`emptyIcon()` / `emptyTitle()` /
`emptyHint()` 三个业务判断留在页面）；22 处 toast、4 处确认框走统一入口；
设置页的分段控件（主题 / 光感挡位 / 编辑体验）从实心强调色块改成浅底 + 强调色字，
与筛选条同一套「已选中」语言。

**阅读页**：删除段落确认框、三处 toast 走统一入口。AI 结果面板的两个按钮原来是
「复制」用强调色浅底 + 强调字、「替换正文」用实心强调底 + `Color.White`——深色主题下
强调色是浅蓝 `#8AB4FF`，白字压上去不可读，而且一个面板里出现了两个强调动作。现在
「复制」是次级底、「替换正文」是强调底，主次分明。

## 文案一个字未改

迁移只换控件，没有改写任何用户可见字符串。两处空态提示一度被顺手改写成新句，已改回
原句：「长按笔记卡片可以删除」「在笔记 frontmatter 里添加 tags 字段后会自动出现在这里。」

## 其他

- 删掉上一轮为了核对排版临时加在阅读页的「预览」调试入口，它不该留在产品里。
- 规范正本见 `docs/ui-consistency.md`（圆角/字号档位、控件使用边界、旧实现对照表）；
  `AGENTS.md` 新增「共用控件层」一节。

---

v1.0.2 的筛选带收放动画见 `docs/release-notes-1.0.2.md`。
完整改动见 `git log v1.0.2..v1.0.3`。
