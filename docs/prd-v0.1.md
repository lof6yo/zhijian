# 鸿蒙 Markdown 笔记应用 · PRD v0.1（草稿）

> 状态：需求收敛中。本文把已确认的决策、技术约束、默认建议和待拍板项放在一起，
> 作为后续设计与实现的单一事实源。未标“已确认”的条目均为默认建议，可改。

## v0.5 变更（包体瘦身）

- **移除 Mermaid / ECharts / 旧 Crepe 编辑器。** 三者在包里合计 9.1 MB（占 HAP
  的 93%），却没有一条 UI 路径能走到：`MdView` 把每个图表块画成「图表渲染未接入」
  占位卡片，`EditorPage` 也没有任何 `pushPath` 入口。release HAP 从 10.5 MB 降到
  ~1.1 MB。
- **块级公式真正接入 KaTeX**（`components/FormulaWeb.ets` + `rawfile/render/
  katex.html`），行内公式由 `MathLite` 线性化成 Unicode 正文。这是全工程唯一保留的
  ArkWeb 用途。图表不再有 `Chart` 块类型，` ```mermaid ` 就是普通围栏代码块。
- 本文下文出现的「Milkdown/Crepe 编辑器」「EditorPage」「Mermaid」均为历史条目，
  以本节为准。

## v0.2 变更（MVP-0 实现时）

- **v0.4：「置顶」整体移除，改为「归档」。** 笔记侧 `pinned` → `archived`
  （frontmatter 字段换名，旧文件的 `pinned:` 会在下次写入时自然消失）；卡片
  右滑轻档变成归档（松手即执行，不弹确认框；长按菜单里的归档才确认）、
  卡片菜单第一项同样；筛选条由 全部/置顶/收藏 变为
  全部/已归档/收藏，归档的笔记只在「已归档」里出现，搜索默认不返回、在结果
  底部提示命中数并可一键全量搜索。标签置顶（`TagStore.pinned`）一并拆除，
  标签页筛选条改为 全部/有笔记。本文下文出现的「置顶」均为历史条目，以本节为准。
- **移除文件夹**：所有 `.md` 平铺在 `notes/` 根目录；底部 Tab 改为
  **笔记 / 标签 / 设置** 3 个。旧 `收件箱/` 下的文件会在启动时自动迁移到根目录。
- 底部 Tab 使用 API 26 的 `Tabs.barFloatingStyle` +
  `uiMaterial.ImmersiveMaterial`（ULTRA_THIN + interactive + lightEffect），
  并在 `module.json5` 开启 `ohos.arkui.UIMaterial.state=enable`。
- **v0.3 修正：底栏改为自绘。** `barFloatingStyle` 悬浮胶囊无法折叠 ——
  `setTabBarTranslate`、`setTabBarOpacity`、动态 `barHeight(0)`、
  `bindTabsToScrollable` 在真机上全部无效；`FloatingTabBarStyle` 只有
  `barWidth/barSideMargin/barBottomMargin/maskColor/maskHeight/systemMaterial`
  字段，没有可见性开关，CLT SDK 也没有 `HdsTabs`。因此 `Tabs` 只保留内容容器
  （`.barHeight(0)`），底栏由 `Index.FloatingBar()` 自绘，用 `@Local barCollapsed`
  驱动 `translate` + `opacity`，才得到“长内容上滑时自动收起”。
- `uiMaterial.ImmersiveMaterial` 在本模拟器的普通页面节点上**不绘制**：把
  `systemMaterial` 加在透明背景容器上会整个消失，`isImmersiveMaterialSupported()`
  为 true 但没有效果；它只在系统悬浮 Tab 栏上真正生效。因此所有悬浮表面都必须
  自带玻璃 token 作为可见基底，材质只是叠加。
- 内容会在其下滚动的悬浮表面（搜索框、筛选条、底栏）用
  `$r('app.color.glass_float')`（85% 不透明）；静态表面用 `glass_bg`（65%）。
  没有模糊时 65% 会让卡片文字穿透并与标签抢视觉。
- **搜索框与底栏同为“沉浸光感”**：搜索框不再压在整块不透明页头上，卡片会从
  搜索胶囊和筛选条下方滚过；页头只有标题带有一条遮罩，且必须是**整条渐变**
  （标题处不透明、chip 处全透明）。不透明底板 + 独立渐隐条会在两者交界留下
  硬边，正好把首张卡片切成两半。
- 悬浮让位靠 `contentEndOffset(118)` 留在滚动内容里，而不是 `padding({bottom})`；
  后者会提前裁剪内容，看不出列表继续延伸到栏下。
- 光感元素扩展：页面级径向光晕（透明 stop + `hitTestBehavior(None)`）、玻璃
  搜索胶囊/筛选条、笔记卡片、标签/设置行。**FAB 已取消**，新建只在标题栏。
- 新建/编辑返回后列表实时刷新：`NavPathStack.setInterception({ didShow })` 在
  `POP` 时执行 `store.reload()` 与 `refreshList()`，把 `store.notes` 复制到
  `@Local notesSnapshot`；列表渲染必须读 `notesSnapshot`，不能直接读单例 store
  （V2 对单例 `@Trace` 数组的跨 NavDestination 依赖不可靠，单独 `listVersion`
  也不会触发重建）。**不要**用 `pushPath({ onPop })`：官方语义是只有
  `pop(result)` 带 result 时才回调。
- `NoteCard` 不接收可变的 `Note` 对象，只接收 `noteId/title/excerpt/tags/archived/
  favorite/updatedAt` primitives；`ForEach` key 使用 `${id}-${updatedAt}`。否则编辑已有
  笔记返回后，卡片会复用旧 `@Param` 对象，标题/摘要要等切 Tab 才更新。
- 编辑器**不再是 ArkWeb + Milkdown/Crepe**（见文首 v0.5）：编辑就发生在阅读页，
  分块模式（默认）点哪块改哪块，简单模式是一个整篇 Markdown 字段。旧的
  `editor-web/` + `rawfile/editor/index.html` 已删除。
- 已实现：本地 `.md`、frontmatter、H1 文件名同步、500ms 自动保存、示例笔记、
  搜索、标签页（增删改/排序/筛选）、3 页签 HDS 悬浮页签栏、卡片四档滑动、
  归档/收藏/标签/删除长按菜单、回收站（30 天）、主题（跟随系统/浅色/深色）、
  强调色、光感挡位、阅读字号/行距、分块与整篇两种编辑体验、格式按钮条、
  块级公式（KaTeX）与行内公式（MathLite）、WebDAV 同步（RCP + 三方合并）。
- 未实现：图片插入闭环、图表、AI、多账号 WebDAV、平板适配。
- 返回刷新机制：所有 `NavDestination` 返回统一由
  `NavPathStack.setInterception({ didShow })` 触发 store 重载。不使用
  `pushPath({ onPop })` —— 官方语义是只有 `pop(result)` 带 result 时才回调，
  普通返回/`pop()` 不会触发，会导致列表停留在旧数据。

## 1. 一句话产品

**手机优先、本地优先的 Markdown 笔记应用**：打开即看到全部笔记卡片，标题栏 `+`
一键新建；正文首个 H1 即标题；可选 WebDAV 同步到自建/第三方远端。

## 2. 目标与非目标

### 已确认的目标

- 快速随手记：App 启动 → 全部笔记卡片 → `+` 新建 → 直接写正文。
- **原生渲染**：输入即排版，但 Markdown 标记不隐藏——点一块改一块，源码就是
  他写下的字符。支持标题、粗体/斜体/删除线、有序/无序/任务列表、引用/分隔线、
  行内代码/代码块、表格、链接、图片、块级公式。
- 组织：平铺 `notes/` + 标签；归档、收藏、回收站 30 天（v0.4 起取代置顶）。
- 搜索：标题 + 正文 + 标签，子串匹配、输入即搜、高亮片段。
- 本地优先：纯 `.md` + YAML frontmatter；每篇一个文件。
- WebDAV：通用 WebDAV、单账号、前台自动 + 手动下拉；冲突保留两份；删除进
  远端 `.trash/` 30 天。
- 导入/导出：Markdown 单篇/批量 + ZIP。
- 主题：跟随系统深浅色 + 5 个背景主题（各带一套强调色）+ 阅读字号/行距。
- 手机竖屏优先；底部 3 页签（笔记/标签/设置），沉浸光感悬浮页签栏。

### 默认非目标（待确认）

- AI 摘要/续写/RAG。
- 图表（Mermaid / ECharts）：曾经的 vendored 引擎已删除，见 v0.5；块级公式已实现
  （KaTeX），行内公式降级为 Unicode 文本。
- 相机拍照/OCR（只做相册选择 + 剪贴板图片）。
- 多端实时协作/共享笔记。
- 应用锁/内容加密（仅系统沙箱 + WebDAV 凭据安全存储）。
- 平板/2in1 适配（首版只保证手机竖屏）。
- 归档~~（只做置顶/收藏/回收站）~~ —— **已改为实现**，见 v0.4；置顶则移除。
- 多 WebDAV 账号/多远端。
- 实时双向同步（只做保存后/启动/前台/手动）。

## 3. 已确认的决策记录

| 维度 | 决策 |
|---|---|
| 产品定位 | 快速随手记 |
| 设备 | 手机优先 |
| 首页 | 全部笔记瀑布流；底部 3 页签（笔记/标签/设置）；沉浸光感悬浮页签栏；**没有 FAB**，新建只在标题栏 |
| 新建位置 | `notes/` 根目录（平铺，无文件夹） |
| 标题 | 正文首个 H1 即标题；文件名同步；重名加后缀 |
| 编辑范式 | 原生就地编辑（`ReaderPage`）：分块（默认）/ 简单整篇，见 v0.2 变更 |
| 源码模式 | **不需要独立源码页** —— 分块编辑显示的就是该块的 Markdown 源码 |
| Markdown 保真 | 源码即规格：不做 WYSIWYG 归一化，写什么存什么 |
| 首版元素 | 标题/粗斜删、列表/任务、引用/分隔线、行内代码/代码块、链接、图片、块级公式 |
| 表格 | 支持（原生渲染，列多横向滚动） |
| 自动保存 | 500ms 防抖 + 退出/切后台立即保存 |
| 组织 | 平铺 `notes/` + 标签 |
| 标签录入 | 卡片长按菜单 ›「标签…」面板（已实现） |
| 排序 | 最近修改 / 按标题 / 按创建（置顶已随 v0.4 移除） |
| 笔记卡片 | 标题 + 2 行摘要 + 标签 + 相对时间 |
| 生命周期 | 归档、收藏、回收站 30 天（置顶已移除，见 v0.4） |
| 标签删除 | 只把标签从笔记里去掉，笔记本身不动 |
| 搜索 | 标题+正文+标签，子串匹配，输入即搜 |
| 存储 | 纯 `.md` + YAML frontmatter；平铺，无文件夹 |
| 附件 | 未实现；计划平铺 `notes/attachments/` + 图片压缩 |
| WebDAV | 通用 WebDAV（RCP）；单账号；`zhijian/` 目录；冲突副本；远端 `.trash/` |
| 首次同步 | 双向三方合并（基线 = 上次确认的远端状态） |
| 同步触发 | 保存后 + 前台心跳 + 手动下拉；仅前台 |
| 同步元数据 | 基线存 preferences 的 `syncBase`；不写远端额外文件 |
| 导入/导出 | `.md` 单篇/批量 + ZIP 含附件 |
| 主题 | 跟随系统 + 5 背景主题（各带一套强调色）+ 字号/行距 |
| 首启 | 欢迎页 + 示例笔记 + 可选 WebDAV |
| 回收站入口 | 设置页 → 回收站 |
| 安全 | 不做应用锁/加密；WebDAV 凭据用 Asset Store Kit |

## 4. 信息架构与核心流程

> **以下 4.x / 5.x / 6.x 是 v0.1 的历史稿**（4 个 Tab、文件夹、Crepe 编辑器）。
> 现行结构以 v0.2/v0.4/v0.5 变更与本仓库 `AGENTS.md` 为准：3 个页签、笔记平铺、
> 原生就地编辑。保留这些段落是为了记录当时的取舍理由，不要照它实现。

### 4.1 底部 3 页签

```text
笔记        标签        设置
```

- **笔记**：页面标题 + 搜索/新建两个圆形按钮；筛选条（全部/已归档/收藏）与
  排序条同一行；2 列 `List` 卡片网格；点卡片进阅读页；长按弹出
  归档/收藏/标签/删除，左右滑动四档（右轻归档、右重删除、左轻收藏、左重 AI 洞见）。
- **标签**：标签列表 + 计数；搜索、新建、排序（名称/数量）、筛选（全部/有笔记）；
  长按弹出 修改/删除；点标签回到笔记页并把标签变成可见的搜索条件。
- **设置**：外观 / 阅读与编辑 / 同步与备份 / 回收站 / 关于。

### 4.2 新建笔记

1. 点标题栏 `+`。
2. 在 `notes/` 根目录创建新 `.md`，直接进 `ReaderPage`。
3. 首个块是 H1（`# 无标题`），光标停在该块；从 `+` 进来的笔记自动进编辑态。
4. 输入 H1 后 500ms：文件名同步为 H1（清洗非法字符、重名加 `(2)`）。
5. 一个字都没写就离开：`purgeNote()` 收掉，不留「无标题」空壳。

### 4.3 阅读页（读与写是同一页）

- 全屏 `NavDestination`；顶部 56 vp 页头（返回 + 笔记标题）。
- 打开即**渲染态**：点正文某一块才编辑那一块（分块）；设置 › 编辑体验 › 简单
  则整篇一个 Markdown 字段。
- 块编辑：源码在上，`预览效果` 在下；右端 删除 / 完成；删一段要确认。
- 格式按钮条（设置里默认关闭）：标题/粗体/斜体/列表/待办/引用/表格/代码。
- 自动保存：500ms 防抖 + 退出立即保存；内容未变不写盘。
- 公式：块级 `$$…$$` 由 KaTeX 渲染；行内 `$…$` 用 `MathLite` 线性化成 Unicode。

## 5. 数据模型

### 5.1 文件布局

```text
<app filesDir>/notes/
├── 买菜清单.md
├── 会议记录.md
└── .trash/
    └── 1750000000000-旧笔记.md
```

- **笔记平铺在 `notes/` 根目录**（v0.2 移除文件夹）。笔记 = 一个 `.md` 文件；
  UTF-8、LF。
- 删除进 `.trash/`，文件名前缀是删除时刻的毫秒数（保留 30 天）。
- 附件：**尚未实现**。计划是平铺的 `notes/attachments/`，Markdown 用相对路径
  引用。

### 5.2 YAML frontmatter

```yaml
---
id: 01JABCDEF...
created: 2026-10-20T12:34:56+08:00
updated: 2026-10-20T12:40:00+08:00
tags: [工作, 想法]
archived: false
favorite: false
---
# 会议记录
正文……
```

- `id`：ULID/UUID，稳定不变；用于同步/冲突/重命名识别。
- `created`/`updated`：ISO 8601；`updated` 在保存时更新。
- `tags`：字符串数组；大小写不敏感匹配，保留用户输入大小写。
- `archived`/`favorite`：布尔。`archived` 为真时笔记只在「已归档」里出现，
  搜索默认不返回；旧文件的 `pinned:` 会被忽略，并在该笔记下次写入时消失。
- **不写 `folder`**：文件夹由路径决定，避免路径与 frontmatter 不一致。
- 未知字段保留原样（导入其他工具的文件时不丢数据）。

### 5.3 索引（内存，可重建）

**没有 RDB。** 索引就是 `NoteStore` 启动时扫一遍 `notes/` 建立的内存数组：每篇
`.md` 读一次 → `Frontmatter` 拆出元数据 → `Note` 对象（`@ObservedV2`）。
搜索是内存里的子串匹配（`haystack = title + '\n' + tags + '\n' + body` 的小写
形式），1000 篇以内是毫秒级。

- 文件是真相，内存索引随时可丢：`store.reload()` 重扫目录即可。
- 同步状态不存 SQLite，而是 `settings.syncBase` 里的一行一条
  （`id \t updatedAt \t relPath`），见 §7 与 `AGENTS.md` §6。
- 之所以不用 RDB：v0.1 设计它时假设 1000+ 篇和 ETag/mtime 缓存，实际规模与
  触发时机都不需要它，多一层缓存反而多一处「索引与文件不一致」的故障面。

## 6. 编辑器技术方案（原生 ArkUI，不是 ArkWeb）

### 6.1 分层

```text
ArkUI 原生外壳
├── 列表/搜索/标签/设置/WebDAV/文件/图片
├── ReaderPage (NavDestination) —— 阅读与编辑是同一页
│   ├── MdView（自研 ArkTS 解析器 + 原生渲染）
│   │   ├── 分块：LiveBlockEditor（该块源码 + 该块预览）
│   │   └── 简单：WholeDocEditor（整篇一个 Markdown 字段）
│   └── FormulaWeb（只有块级 $$…$$）→ rawfile/render/katex.html
└── 状态栏/手势条由 common/WindowService 统一着色
```

### 6.2 关键约束（实测结论）

- **没有原生现成 WYSIWYG 框架**；RichEditor 的 builder span 不可回读、无
  `undo()/redo()`、无表格，不能做块级 WYSIWYG。**结论：自研解析器 + 原生渲染**，
  而不是把 Crepe 塞进 WebView（那条路已试过并删除，见 v0.5）。
- **源码即规格**：分块编辑显示的就是该块的 Markdown 源码，不做归一化，因此不存在
  「往返保真」这一整类问题。
- **正文不能走 WebView**：一屏几十个块会让原生滚动、文本选择、批注坐标、字号设置
  全部失效。唯一例外是块级公式——它是有确定尺寸的独立块。
- **行内 `$…$` 不挂 WebView**：`MathLite` 线性化成 Unicode 文本（`E = mc²`），
  不加代码底色。一屏十几个行内公式＝十几个浏览器进程。
- **包体门槛**：任何新引擎进包前必须先证明有一条 UI 路径会执行它。Mermaid +
  ECharts 6.5 MB 曾经进去了、一次都没跑过（见 v0.5）。
- **中文 IME**：`LiveBlockEditor` 的草稿用 `@Monitor('initialSource')` 重播，不用
  `aboutToAppear`——同一结构位置上换块会复用实例，`aboutToAppear` 不会再跑。

### 6.3 Go/No-Go 清单（当前版本）

| # | 检查 | 通过标准 |
|---|---|---|
| 1 | 打开一篇笔记 | 渲染态立即可见，无白屏 |
| 2 | 中文 IME 100 字 | 0 丢字、光标不跳 |
| 3 | 任务列表/代码块/引用/表格 | 点一下勾选真落盘，渲染与源码一致 |
| 4 | 块级公式 | KaTeX 渲染；损坏的 LaTeX 退回 `MathLite` 文本 |
| 5 | 行内公式 | 显示为 Unicode 近似，无代码底色 |
| 6 | 5 万字符文档 | 解析 <150 ms，滚动 55+ fps |
| 7 | 误触新建 | 立即返回后列表里没有「无标题」空壳 |
| 8 | 键盘/深色模式 | 光标不被遮挡；状态栏与页面背景连续 |

## 7. WebDAV 同步

### 7.1 配置

- 单账号：URL、远程根目录、用户名、应用密码；保存前测试连接
  （PROPFIND + 写测试文件）。
- 凭据存 Asset Store Kit；不写 frontmatter、不写日志。
- 仅 HTTPS；自签名证书通过 `caPath` 指定 CA；不支持 Digest Auth（UI 说明
  使用应用密码/Basic）。

### 7.2 协议

**不要用 `@ohos.net.http`。** 它的 `RequestMethod` 是封闭枚举，没有
PROPFIND/MKCOL/MOVE，WebDAV 无法用它对任何形式表达。实现用
`@kit.RemoteCommunicationKit`（RCP）：`rcp.HttpMethod` 接受任意动词，
`security.serverAuthentication` 原生做 RFC 7617 basic auth。

- `dns` 与 `proxy` 挂在 `requestConfiguration`（`rcp.Configuration`），不在
  `SessionConfiguration`。`StaticDnsRule` 按 **host + port** 匹配，端口必须从
  URL 取；HTTPS 走代理时 `WebProxy.createTunnel` 必须是 `'always'`。
- XML 用「按 `<...response` 边界切分 + 容忍前缀的正则」解析。`convertxml`
  返回无类型 `object`（ArkTS 禁用），`XmlPullParser` 的 `tagValueCallbackFunction`
  只对有文本的元素触发，`<D:collection/>` 会看不见。
- 必需方法：PROPFIND Depth 1、MKCOL（405=已存在）、PUT、GET、DELETE、
  MOVE（Destination 绝对 URL，405/501 回退 GET→PUT→DELETE）。
- 5xx 或传输异常重试 3 次：代理隧道偶发 `500 Connection established`，
  那是代理的 CONNECT 状态而非源站应答。

### 7.3 同步语义

- 触发：**仅前台**（30 秒心跳 + 一条策略；心跳本身不发请求）+ 手动下拉
  （跳过间隔与退避）。不做后台同步：本地优先的应用不应在用户不知情时上传内容。
- 远端是专用 `zhijian/` 目录，`MKCOL` 自动创建，不碰用户的 `Obsidian/`。
- **身份是 frontmatter 的 `id`，不是文件名**。未命名的笔记在每台设备上都叫
  「无标题」，按名字配会把无关笔记合并。
- **三方合并，基线 ≠ 时间戳猜测**。`settings.syncBase` 每条
  `id \t updatedAt \t relPath`；只有**确认到达服务器**的操作才写基线。失败的 PUT
  不写行，下一轮仍然看到「本地变了、远端没变」并重试。
- 远端读取失败**中止整轮**：部分列表会让「没读到的 id」被判定为「远端删了」，
  然后删掉本地数据。
- `updatedAt` 单调：远端比本地旧的一律不采纳，本地重新上传。
- 一个 `id` 只能占一个远端路径；本轮推过的那条 id 之外的同 id 文件要删掉。
- 冲突副本 `<标题> (冲突 HHmm).md` + 新 id，**两边正文都留下**，并且标记写进
  正文 H1（列表渲染的是 H1，只改文件名会留下两张同名卡片）。
- 删除双向传播，基线行同时充当墓碑：本地少了但基线有 → 远端 MOVE 到
  `zhijian/.trash/<millis>-<name>.md`；远端少了但基线有 → 本地进回收站。
  删除**只有确认发生**才删基线行。

## 8. 搜索

- 范围：当前页签（笔记页按筛选条再收窄）；搜索词跨页签共享，切页签清空。
- 输入即搜；标题命中优先，其次 `updatedAt` 倒序。
- 内存子串匹配（大小写不敏感），中文天然可用。
- 片段：命中位置 ±40 字符，返回 `{before, match, after}` 给 UI 用 Span 高亮。
- 规模：<1000 篇、单篇 <100KB；解析性能由 `tools/md-parse-check.js` 的
  performance 段守着（100 KB / ≈2900 块 < 150 ms）。

## 9. 导入/导出

- 导出：单篇/选中/整库为 `.md` 或 ZIP；ZIP 根目录平铺（无文件夹）。
- 导入：`.md` 单篇/多选；同名笔记生成冲突副本。
- frontmatter 保留；未知字段保留；导入时缺 `id` 则生成。
- 导入冲突：`会议 (导入冲突 2026-10-20).md`。
- 当前状态：入口在 设置 › 同步与备份，尚未实现文件选择器闭环。

## 10. 主题与视觉

- 跟随系统深浅色；5 个背景主题（黄山 / 龙脊 / 长白 / 沙海 / 呼伦）。每个主题
  自带一套强调色，**强调色由主题派生**，不是独立设置项：界面上只有一档色相
  选择，避免「沙海背景 + 黄山蓝按钮」这种两套色相打架的组合。
- 背景是一层真实地形的等高线（构建期从公开 DEM 提取，运行期只画线），主题决定
  底色渐变与线色。可读性预算是硬指标：普通线 ΔL ≤16（浅）/ ≤14（深），计曲线
  ≤26 / ≤18，验算工具为 `tools/contour-budget.js`。
- 强调色是**运行时可切换**的，因此不能只用 `$r('app.color.accent')`：ArkUI 在
  编译期解析资源。所有强调色相关颜色集中在
  `common/Palette.ets` 的 `AccentScheme`，每套配色都有 light/dark 两套值
  （深色用提亮降饱和的色相，避免纯饱和色在深底上对比不足）。新增需要跟随
  强调色的组件时，用 `@Param accentColor: string` 传入，不要回退到资源。
- 底部 3 页签使用 HDS 的沉浸光感悬浮页签栏（`HdsTabs` +
  `barFloatingStyle`），宽度按窗口宽度分桶；API < 23 退回 `Index.PlainShell()`。
  **不要再手绘浮动胶囊**：HDS 的页签栏不接受外部 `translate`/`opacity`，
  旧的自绘实现只为伪造「上滑收起」。
- 光感表面用 `systemMaterial`（`MaterialLayer` 的 `Toggle` 载体）+ `glassTint` 半透明
  遮罩；`backgroundBlurStyle` 在页面内不生效，不要用它冒充玻璃。
- 笔记卡片 2 列 `List` + `lanes(2)`：标题 + 2 行摘要 + 最多 3 个标签 + 相对时间。
- 编辑器字号（14–22 px）与行距（0.75–1.50 倍）可调，经 `SettingsStore` 持久化，
  由 `ReaderPage.typography()` 直接作为 `@Param` 传给 `MdView`；**没有 CSS 变量**
  这一层，改值即重绘。

## 11. 技术架构

```text
entry/src/main/ets/
├── entryability/       EntryAbility（生命周期 + 前台心跳驱动自动同步）
├── pages/              Index（3 页签）、ReaderPage、TrashPage、WebDavPage
├── components/         NoteCard、CardSurface、MaterialLayer、FormulaWeb
├── markdown/           MdTypes / MdParser / CodeHighlight / MathLite /
│                       MdView / LiveBlockEditor / WholeDocEditor
├── models/             Note（V2 @ObservedV2/@Trace）
├── services/           NoteStore、Frontmatter、TagStore、WebDav、SyncEngine、
│                       Credentials、SettingsStore
└── common/             WindowService、Palette
entry/src/main/resources/rawfile/render/
├── katex.html          # 唯一的 Web 渲染页（块级公式）
└── vendor/             # katex.min.js + .css + 20 个 woff2（离线）
```

- 单 HAP；暂不拆 HAR/HSP。文件是真相，索引是内存里的 `NoteStore.notes`。
- 页面/组件用 V2 状态；Navigation + NavPathStack；资源 + dark 变体。
- 权限：`ohos.permission.INTERNET`；相册用 PhotoPicker，不申请宽泛存储权限。

## 12. 验收标准（当前版本）

- [x] 标题栏 `+` 新建 → H1 输入 → 文件名同步 → 500ms 自动保存 → 重开内容一致。
- [x] 原生渲染 7 类元素（标题/列表/引用/表格/代码/公式/分隔线）；中文输入 100 字不丢字。
- [x] 笔记平铺 + 标签可增删改（在卡片长按菜单的标签面板里）。
- [x] 搜索标题/正文/标签，200ms 内出结果。
- [x] 删除进回收站，30 天可恢复。
- [x] 系统深浅色 + 5 背景主题（各带一套强调色）+ 字号/行距；3 页签 HDS 悬浮页签栏。
- [x] 块级公式 KaTeX 渲染，行内公式 Unicode 线性化。
- [ ] WebDAV 单账号配置/测试/保存后同步/启动同步/手动同步；冲突副本。
- [ ] 导入/导出 `.md` + ZIP。
- [ ] 图片插入闭环（选择器 → 沙箱 → 相对路径 → `MdView` 真渲染 `Image`）。
- [ ] 1000 篇列表首屏 <1s；100KB 笔记编辑流畅；无崩溃/无数据丢失。

## 13. 待拍板

1. **标签录入**：标签面板（已实现）/ 正文 `#tag` / 两者都支持？（当前：标签面板）
2. **搜索范围**：全局 + 筛选 / 仅当前视图？（当前：跟随当前页签与筛选）
3. **图表**：不做 / 自研极简 flowchart / 验证过的 Mermaid 子集？
   （当前：不做；` ```mermaid ` 是普通代码块）
4. **本地化**：首版仅中文，还是中英双语？（当前：仅中文）

## 14. 参考

- 技术调研：`docs/vibe-coding-harmonyos.md`
- Markdown 引擎契约：`docs/markdown-engine.md`
- 官方：RichEditor、Web 组件、NetworkKit、RemoteCommunicationKit、Asset Store Kit
- KaTeX 0.19.0（MIT，离线 vendored）
