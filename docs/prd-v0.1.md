# 鸿蒙 Markdown 笔记应用 · PRD v0.1（草稿）

> 状态：需求收敛中。本文把已确认的决策、技术约束、默认建议和待拍板项放在一起，
> 作为后续设计与实现的单一事实源。未标“已确认”的条目均为默认建议，可改。

## v0.2 变更（MVP-0 实现时）

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
  搜索/筛选条、玻璃笔记卡片、标签/设置行、FAB 径向光晕 + 实心强调色按钮。
- 新建/编辑返回后列表实时刷新：`pushPath` 的 `onPop` 回调执行
  `store.reload()`，把 `store.notes` 复制到 `@Local notesSnapshot`，再
  `listVersion++`；列表渲染必须读 `notesSnapshot`，不能直接读单例 store
  （V2 对单例 `@Trace` 数组的跨 NavDestination 依赖不可靠，单独 `listVersion`
  也不会触发重建）。`EditorPage` 返回时 `pop({ saved: true })`，系统返回由
  `NavDestination.onBackPressed` 同样处理。
- `NoteCard` 不接收可变的 `Note` 对象，只接收 `noteId/title/excerpt/tags/pinned/
  updatedAt` primitives；`ForEach` key 使用 `${id}-${updatedAt}`。否则编辑已有
  笔记返回后，卡片会复用旧 `@Param` 对象，标题/摘要要等切 Tab 才更新。
- 编辑器确定为 ArkWeb + Milkdown/Crepe；Vite `vite-plugin-singlefile` 输出单文件
  `rawfile/editor/index.html`，规避 `resource://` CORS；CSS 覆盖 Crepe 的桌面
  120px padding，手机全宽。
- 已实现：本地 `.md`、frontmatter、H1 文件名同步、500ms 自动保存、示例笔记、
  搜索、标签页、3 Tab 悬浮底栏、置顶/收藏/删除长按菜单、回收站（30 天）、
  导入/导出（`.md` + ZIP）、主题（跟随系统/浅色/深色）、背景样式、强调色、
  编辑器字号/行距。
- 未实现：WebDAV、源码模式、图片插入、格式工具栏、多文件夹。
- 返回刷新机制：所有 `NavDestination` 返回统一由
  `NavPathStack.setInterception({ didShow })` 触发 store 重载。不使用
  `pushPath({ onPop })` —— 官方语义是只有 `pop(result)` 带 result 时才回调，
  普通返回/`pop()` 不会触发，会导致列表停留在旧数据。

## 1. 一句话产品

**手机优先、本地优先、WYSIWYG 的 Markdown 快记应用**：打开即看到全部笔记瀑布流，
FAB 一键新建；正文首个 H1 即标题；可选 WebDAV 同步到自建/第三方远端。

## 2. 目标与非目标

### 已确认的目标

- 快速随手记：App 启动 → 全部笔记瀑布流 → FAB 新建 → 直接写正文。
- WYSIWYG：输入即渲染、隐藏 Markdown 标记；支持标题、粗体/斜体/删除线、
  有序/无序/任务列表、引用/分隔线、行内代码/代码块、链接、图片。
- 组织：收件箱 + 单层文件夹 + 标签；置顶、收藏、回收站 30 天。
- 搜索：标题 + 正文 + 标签，子串匹配、输入即搜、高亮片段。
- 本地优先：纯 `.md` + YAML frontmatter；每篇一个文件，文件夹即目录。
- WebDAV：通用 WebDAV、单账号、保存后自动 + 启动/前台 + 手动；默认仅 Wi-Fi；
  冲突保留两份；删除进远端 `.trash/` 30 天。
- 导入/导出：Markdown 单篇/批量 + ZIP（含附件）。
- 主题：跟随系统深浅色 + 3 个强调色 + 编辑器字号/行距。
- 手机竖屏优先；底部 4 Tab（笔记/文件夹/标签/设置），沉浸光感悬浮 Tab。

### 默认非目标（待确认）

- AI 摘要/续写/RAG。
- 表格、数学公式、Mermaid。
- 相机拍照/OCR（只做相册选择 + 剪贴板图片）。
- 多端实时协作/共享笔记。
- 应用锁/内容加密（仅系统沙箱 + WebDAV 凭据安全存储）。
- 平板/2in1 适配（首版只保证手机竖屏）。
- 归档（只做置顶/收藏/回收站）。
- 多 WebDAV 账号/多远端。
- 实时双向同步（只做保存后/启动/前台/手动）。

## 3. 已确认的决策记录

| 维度 | 决策 |
|---|---|
| 产品定位 | 快速随手记 |
| 设备 | 手机优先 |
| 首页 | 全部笔记瀑布流；底部 4 Tab；沉浸光感悬浮 Tab；FAB 新建 |
| 新建位置 | 当前文件夹；无则收件箱 |
| 标题 | 正文首个 H1 即标题；文件名同步；重名加后缀 |
| 编辑范式 | WYSIWYG（ArkWeb + Milkdown/Crepe） |
| 源码模式 | 可编辑源码切换（独立 source 页） |
| Markdown 保真 | 接受 ProseMirror 规范化；源码模式兜底 |
| 首版元素 | 标题/粗斜删、列表/任务、引用/分隔线、行内代码/代码块、链接、图片 |
| 表格 | 不做 |
| 自动保存 | 500ms 防抖 + 退出/切后台立即保存 |
| 组织 | 收件箱 + 单层文件夹 + 标签 |
| 标签录入 | 默认建议：元数据面板（待确认） |
| 排序 | 置顶优先，其余按更新时间倒序 |
| 笔记卡片 | 标题 + 2 行摘要 + 标签 + 相对时间 |
| 生命周期 | 置顶、收藏、回收站 30 天；不做归档 |
| 删除文件夹 | 笔记回收件箱；标签删除只移除标记 |
| 搜索 | 标题+正文+标签，子串匹配，输入即搜 |
| 存储 | 纯 `.md` + YAML frontmatter；文件夹即目录 |
| 附件 | 每文件夹 `attachments/`；图片自动压缩 |
| WebDAV | 通用 WebDAV；单账号；镜像目录；冲突副本；远端 `.trash/` |
| 首次同步 | 双向合并 + 冲突副本 |
| 同步触发 | 保存后 + 启动/前台 + 手动；默认仅 Wi-Fi |
| 同步元数据 | 不写远端额外文件；本地 RDB 记 ETag/mtime/hash |
| 导入/导出 | `.md` 单篇/批量 + ZIP 含附件 |
| 主题 | 跟随系统 + 3 强调色 + 字号/行距 |
| 首启 | 欢迎页 + 示例笔记 + 可选 WebDAV |
| 回收站入口 | 设置页 → 回收站 |
| 安全 | 不做应用锁/加密；WebDAV 凭据用 Asset Store Kit |

## 4. 信息架构与核心流程

### 4.1 底部 4 Tab

```text
笔记        文件夹        标签        设置
```

- **笔记**：顶部搜索框 + 筛选 chip（全部/置顶/收藏）；2 列瀑布流卡片；
  右下 FAB。点卡片进编辑页；长按弹出置顶/收藏/移动/删除。
- **文件夹**：收件箱 + 用户文件夹（单层）；显示笔记数；新建/重命名/删除；
  点文件夹进入该文件夹的笔记列表。
- **标签**：标签列表 + 计数；新建/重命名/删除；点标签筛选笔记。
- **设置**：WebDAV 账号与同步、主题/强调色/字号/行距、回收站、导入/导出、关于。

### 4.2 新建笔记

1. 点 FAB。
2. 在当前文件夹（文件夹 Tab/文件夹筛选下）或收件箱创建新 `.md`。
3. 进入编辑页；首个块是 H1，占位“标题”；光标在正文第一行。
4. 输入 H1 后失焦/暂停 500ms：文件名同步为 H1（清洗非法字符、重名加 `(2)`）。
5. 无 H1 时：文件名用时间戳/首行摘要；列表显示“无标题”。

### 4.3 编辑页

- 全屏 `NavDestination`；顶部返回、更多菜单（笔记信息/源码模式/删除）。
- 正文 WYSIWYG；底部浮动格式工具栏（键盘上方）。
- 格式工具栏：H1/H2/H3、粗体、斜体、删除线、无序/有序/任务列表、引用、
  行内代码、代码块、链接、图片。
- Markdown 快捷输入：`# `、`- `、`1. `、`> `、`[] `、```` ``` ````、
  `**`、`~~`、`[]()`。
- 图片：相册选择/剪贴板粘贴 → 压缩 → 存 `attachments/` → 插入相对路径。
- 自动保存：500ms 防抖 + 切后台/退出立即保存；崩溃恢复草稿。
- 源码模式：独立 `source.html`（`<textarea>`，v1 不做高亮）；切换前把当前
  Markdown 传给源码页；返回时把源码保存回原生并重载 WYSIWYG。模式切换作为
  提交点，清空 undo 栈（产品语义需在 UI 说明）。

## 5. 数据模型

### 5.1 文件布局

```text
<app filesDir>/notes/
├── 收件箱/
│   ├── 买菜清单.md
│   └── attachments/
│       └── img-<hash>.jpg
├── 工作/
│   ├── 会议记录.md
│   └── attachments/
└── 想法/
    └── ...
```

- 文件夹 = 目录；单层；笔记只能属于一个文件夹。
- 笔记 = 一个 `.md` 文件；UTF-8、LF。
- 附件 = 笔记所在文件夹的 `attachments/`；Markdown 用相对路径
  `attachments/img-<hash>.jpg`。
- 笔记移动到另一个文件夹时：复制/移动被引用的附件到目标 `attachments/`
  （按内容 hash 去重），重写相对路径；仍被其他笔记引用的附件保留原处。
  这是“每文件夹 attachments”带来的必要成本。

### 5.2 YAML frontmatter

```yaml
---
id: 01JABCDEF...
created: 2026-10-20T12:34:56+08:00
updated: 2026-10-20T12:40:00+08:00
tags: [工作, 想法]
pinned: false
favorite: false
---
# 会议记录
正文……
```

- `id`：ULID/UUID，稳定不变；用于同步/冲突/重命名识别。
- `created`/`updated`：ISO 8601；`updated` 在保存时更新。
- `tags`：字符串数组；大小写不敏感匹配，保留用户输入大小写。
- `pinned`/`favorite`：布尔。
- **不写 `folder`**：文件夹由路径决定，避免路径与 frontmatter 不一致。
- 未知字段保留原样（导入其他工具的文件时不丢数据）。

### 5.3 本地 RDB（索引，可重建）

```sql
note(
  id TEXT PRIMARY KEY,
  rel_path TEXT UNIQUE,
  title TEXT,
  body TEXT,
  frontmatter TEXT,
  tags TEXT,            -- 归一化 ',tag1,tag2,'
  created_at INTEGER,
  updated_at INTEGER,
  remote_etag TEXT,
  remote_mtime INTEGER,
  local_dirty INTEGER,
  deleted INTEGER,
  deleted_at INTEGER
);
note_search(note_id INTEGER PRIMARY KEY, haystack TEXT);
folder(name TEXT PRIMARY KEY, created_at INTEGER);
tag(name TEXT PRIMARY KEY, color TEXT NULL);
```

- 文件是真相；RDB 是索引/同步状态；启动时按目录扫描增量重建。
- 保存：同一事务 upsert `note` + `note_search` + `folder/tag` 计数。
- 搜索：`haystack = lower(title + '\n' + tags + '\n' + body)`；
  `LIKE '%' || lower(?) || '%' ESCAPE '\'`；对 `%`/`_` 转义；<1000 篇预计
  5–25ms，先测量再决定是否加倒排索引。

## 6. 编辑器技术方案（ArkWeb + Milkdown/Crepe）

### 6.1 分层

```text
ArkUI 原生外壳
├── 列表/搜索/文件夹/标签/设置/WebDAV/文件/图片
├── EditorPage (NavDestination)
│   └── Web (rawfile/editor/index.html)
│       ├── Milkdown Crepe (WYSIWYG)
│       ├── javaScriptProxy: save / pickImage / openLink / setTheme
│       └── onInterceptRequest: mdimg:// 相对路径图片
└── 只读预览/列表摘要：可复用 MdParser + MdRenderer（native）
```

### 6.2 关键约束（来自 2026-10-20 spike）

- **没有原生现成 WYSIWYG 框架**；RichEditor 的 builder span 不可回读、无
  `undo()/redo()`、无表格，不能做块级 WYSIWYG。
- Crepe **没有内置源码模式**；源码模式用独立 `source.html`（v1：`<textarea>`），
  不用同页 CodeMirror，避免 IME/事件冲突。
- 图片用 `mdimg://` 自定义 scheme + `onInterceptRequest`；不要用 blob/data URL
  （会写进 `.md` 或刷新失效）。
- `javaScriptProxy` 大 payload 用 `asyncMethodList`；文档传输分片或
  `runJavaScriptExt`。
- 中文 IME：`compositionstart/end` 期间冻结 replace 类 decoration；PoC 必须
  在模拟器 + 真机各测 100 字。
- 键盘：`keyboardAvoidMode(RESIZE_VISUAL)`；外层不要同时加 Scroll；单滚动容器。
- 深色模式：原生 `onConfigurationUpdate` → `runJavaScript` 注入主题 class；
  不依赖 CSS `prefers-color-scheme`。
- 包体：Crepe + ProseMirror + remark 约 350–600KB gzip；不引入 KaTeX/Mermaid。
- 往返保真：Crepe 会规范化列表符号/强调符号/空行/链接编码。已选“接受规范化 +
  源码模式兜底”；**PoC 必须量化**：10 篇真实笔记打开→保存，统计被改写比例。
  若 >30% 或中文 IME 丢字，自动切换 CodeMirror 6（文本即真相）作为 Plan B。

### 6.3 Go/No-Go PoC（1 天）

| # | 检查 | 通过标准 |
|---|---|---|
| 1 | ArkWeb 加载 Crepe | `onPageEnd` 后 <800ms 可输入 |
| 2 | 中文 IME 100 字 | 0 丢字、0 候选框闪烁、光标不跳 |
| 3 | 任务列表/代码块/引用 | 输入即渲染，保存后重新加载一致 |
| 4 | 图片插入 | `mdimg://` 显示；冷启动仍显示；`../` 越权被拒 |
| 5 | 源码切换 | 内容一致；切换不丢字；undo 语义可接受 |
| 6 | Markdown 往返 | 10 篇真实笔记 diff 统计；>30% 改写 → 切 CM6 |
| 7 | 5 万字符文档 | 输入延迟 <50ms，滚动 55+ fps |
| 8 | 键盘/深色模式 | 光标不被遮挡；主题跟随 |

## 7. WebDAV 同步

### 7.1 配置

- 单账号：URL、远程根目录、用户名、应用密码；保存前测试连接
  （PROPFIND + 写测试文件）。
- 凭据存 Asset Store Kit；不写 frontmatter、不写日志。
- 仅 HTTPS；自签名证书通过 `caPath` 指定 CA；不支持 Digest Auth（UI 说明
  使用应用密码/Basic）。

### 7.2 协议

`@ohos.net.http` 的 `RequestMethod` 是封闭字符串枚举，没有 PROPFIND/MKCOL/
MOVE/COPY。首选方案：

```ts
const options: http.HttpRequestOptions = {
  method: 'PROPFIND' as http.RequestMethod, // 运行时字符串透传，需 30 分钟真机探测
  header: { Depth: '1', Authorization: 'Basic ...' },
  extraData: propfindXml,
  expectDataType: http.HttpDataType.STRING,
  connectTimeout: 15000,
  readTimeout: 30000
};
```

- **先做 30 分钟探测**：若被底层拦截（BusinessError），降级
  `@ohos.net.socket` + TLS，只实现 PROPFIND/PUT/GET/DELETE/MKCOL/MOVE 六个方法。
- XML 用 `@ohos.xml` pull parser，按 localName 匹配（命名空间前缀不固定）。
- 必需方法：PROPFIND Depth 1（207）、MKCOL（405=已存在）、PUT（If-Match/
  If-None-Match，412=冲突）、GET、DELETE（404 幂等）、MOVE（Destination 绝对 URL）。
- 串行同步队列 + 指数退避；失败项进重试。

### 7.3 同步语义

- 触发：保存后（防抖）+ 启动/前台 + 手动；默认仅 Wi-Fi，可配置。
- 远端镜像本地目录：`工作/会议.md`、`工作/attachments/...`；
  远端根目录由用户选择。
- 首次同步：双向合并；远端独有→下载；本地独有→上传；同路径两边都改→冲突副本。
- 冲突：`会议.conflict-20261020-123456.md`，绝不静默覆盖；保留两边内容。
- 删除：远端移到 `.trash/<原相对路径>`；30 天后清理；本地回收站同语义。
- 重命名/移动：优先 `MOVE`；失败回退 PUT+DELETE；用 `id` + 内容 hash 识别
  远端“删除+新增”其实是重命名。
- 不写远端元数据目录；本地 RDB 记 `remote_etag`/`remote_mtime`/`local_dirty`/
  `deleted_at`。代价：删除墓碑/重命名检测是 best-effort，冲突副本可能更多；
  这是用户明确选择的取舍。

## 8. 搜索

- 范围：全局；结果页可按文件夹/标签 chip 筛选。
- 输入 200ms 防抖；标题命中优先，其次 `updated_at` 倒序。
- `LIKE` 子串匹配，中文天然可用；`%`/`_` 转义。
- 片段：命中位置 ±40 字符，返回 `{before, match, after}` 给 UI 用 Span 高亮。
- 规模：<1000 篇、单篇 <100KB；若实测 >100ms，再加 bigram 倒排表。

## 9. 导入/导出

- 导出：单篇/选中/整库为 `.md` 或 ZIP；ZIP 根目录镜像本地文件夹：
  `工作/会议.md`、`工作/attachments/img.jpg`。
- 导入：`.md` 单篇/多选；ZIP 按目录恢复文件夹；同名笔记生成冲突副本；
  附件按相对路径归位。
- frontmatter 保留；未知字段保留；导入时缺 `id` 则生成。
- 导入冲突：`会议 (导入冲突 2026-10-20).md`。

## 10. 主题与视觉

- 跟随系统深浅色；3 个强调色（蓝 / 青 / 橙）。
- 强调色是**运行时可切换**的，因此不能只用 `$r('app.color.accent')`：ArkUI 在
  编译期解析资源。所有强调色相关颜色集中在
  `common/Palette.ets` 的 `AccentScheme`，每套配色都有 light/dark 两套值
  （深色用提亮降饱和的色相，避免纯饱和色在深底上对比不足）。新增需要跟随
  强调色的组件时，用 `@Param accentColor: string` 传入，不要回退到资源。
- 底部 3 Tab 使用沉浸光感悬浮材质；注意 `ohos.arkui.UIMaterial.state`
  metadata。**底栏由 `Index.FloatingBar()` 自绘**，`Tabs` 只当内容容器
  （`.barHeight(0)`）：`barFloatingStyle` 胶囊在任何运行时 API 下都不能折叠，
  自绘才能用 `translate` + `opacity` 实现“上滑收起、下滑/到顶恢复”。
- 页面本体的玻璃效果用 `backgroundColor(glass_bg)` + 发丝边框 + 阴影，
  **不要**加 `backgroundBlurStyle`：API 26 下页面内模糊不生效，只是多一次
  渲染开销，卡片多时会掉帧。内容会滚到其下的表面改用 `glass_float`。
- 笔记卡片 2 列瀑布流：标题 + 2 行摘要 + 最多 3 个标签 + 相对时间。
- 编辑器字号（14–22 px）与行距（1.40–2.20 倍）可调，经 `SettingsStore`
  持久化，由 `EditorPage` 在 `onPageEnd` 通过
  `__setTypography(fontSize, lineHeight)` / `__setAccent(color)` 注入
  CSS 变量；改值不重建 Crepe。

## 11. 技术架构

```text
entry/src/main/ets/
├── entryability/
├── pages/            Index（4 Tab）、EditorPage、SettingsPage、WebDavPage、TrashPage
├── components/       NoteCard、NoteWaterfall、FolderList、TagList、EditorToolbar、EmptyState
├── viewmodels/       NotesVM、EditorVM、SyncVM、SettingsVM
├── models/           Note、Folder、Tag、SyncState、Frontmatter
├── services/         NoteRepository、FileStore、FrontmatterCodec、SearchIndex、
│                     WebDavClient、SyncService、ImageService、ImportExportService、
│                     SettingsService、AssetStoreService
└── common/           Logger、Constants、Theme、Result
entry/src/main/resources/rawfile/editor/   # Milkdown/Crepe Vite 产物
```

- 单 HAP；暂不拆 HAR/HSP。文件是真相，RDB 是索引。
- 写文件/解析/搜索/同步放 `taskpool`；RDB 写由 `NoteRepository` 串行化。
- 页面/组件用 V2 状态；Navigation + NavPathStack；资源 + dark 变体。
- 权限：`ohos.permission.INTERNET`；相册用 PhotoPicker，不申请宽泛存储权限。

## 12. 验收标准（MVP）

- [ ] FAB 新建 → H1 输入 → 文件名同步 → 500ms 自动保存 → 重开内容一致。
- [ ] WYSIWYG 支持 7 类元素；中文输入 100 字不丢字；源码模式可编辑并回写。
- [ ] 收件箱/单层文件夹/标签可增删改；移动笔记附件路径正确。
- [ ] 搜索标题/正文/标签，200ms 内出结果并高亮。
- [ ] 删除进回收站，30 天可恢复；WebDAV 远端 `.trash/` 同步。
- [ ] WebDAV 单账号配置/测试/保存后同步/启动同步/手动同步；冲突副本。
- [ ] 导入/导出 `.md` + ZIP；目录与附件正确。
- [ ] 系统深浅色 + 3 强调色 + 字号/行距；4 Tab 悬浮材质。
- [ ] 1000 篇列表首屏 <1s；100KB 笔记编辑流畅；无崩溃/无数据丢失。

## 13. 待拍板（写代码前需要确认）

1. **PoC 失败规则**：Crepe 往返改写 >30% 或中文 IME 丢字时，是否自动切
   CodeMirror 6？（默认：是）
2. **标签录入**：元数据面板 / 正文 `#tag` / 两者都支持？（默认：元数据面板）
3. **瀑布流列数**：2 列 / 1 列 / 自适应？（默认：2 列）
4. **搜索范围**：全局 + 筛选 / 仅当前文件夹？（默认：全局 + 筛选）
5. **ZIP 导入**：按目录恢复 + 冲突副本 / 全部进收件箱？（默认：按目录恢复）
6. **非目标确认**：AI、表格、数学/Mermaid、相机/OCR、协作、应用锁/加密、
   平板、归档、多账号 WebDAV 是否全部不做？（默认：全部不做）
7. **应用名/包名**：继续 HMStart 占位，发布前再定？（默认：是）
8. **本地化**：首版仅中文，还是中英双语？（默认：仅中文）
9. **WebDAV 探测**：是否先做 30 分钟 `PROPFIND as RequestMethod` 真机探测？
   （默认：是，先于一切开发）

## 14. 参考

- 技术调研：`docs/vibe-coding-harmonyos.md`
- 本地旧工程：`D:\simple-markdown-HMOS`（MdParser/MdRenderer 可复用）
- 官方：RichEditor、Web 组件、NetworkKit、relationalStore、Asset Store Kit
- Milkdown/Crepe、ProseMirror、remark
