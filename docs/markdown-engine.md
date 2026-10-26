# Markdown 引擎 · 契约与实现约定

本文件是 `entry/src/main/ets/markdown/` 的设计契约。三个模块并行开发，任何一方
改签名都必须先改这里。

## 0. 技术路线（与参考实现 LiteMdReader 对齐）

| 层 | 做法 | 为什么 |
|---|---|---|
| 解析 | **自研 ArkTS 解析器**，扁平 AST | 不引第三方 Markdown 库；扁平结构避开 ArkUI 不能递归自引用组件的限制 |
| 正文渲染 | **原生 ArkUI**（`Text { Span }` / 原生布局） | 不起 WebView。一屏几十个块走 WebView 会直接卡死，且无法用原生滚动/选区 |
| 代码高亮 | **自研分词器**，按语言族 | 同上，不能为了高亮再挂一个 Web 引擎 |
| 数学公式（块级） | ArkWeb 加载离线 **KaTeX**（`rawfile/render/katex.html`） | KaTeX 是 MIT，公式排版复杂度不值得自研 |
| 数学公式（行内） | 自研 `MathLite` 线性化成 Unicode 文本 | 一屏十几个行内公式＝十几个 WebView 进程 |
| 图表 | **不支持**（围栏按普通代码块高亮） | 曾经 vendored Mermaid + ECharts（6.5 MB），但从未渲染过；见下 |

**唯一允许出现 ArkWeb 的地方是块级公式。** 正文、标题、列表、表格、代码、行内
公式全部原生渲染。这条是硬约束：正文走 WebView 会让原生滚动、文本选择、批注坐标、
字号设置全部失效。

第三方运行时的授权：只剩 KaTeX MIT。清单见
`entry/src/main/resources/rawfile/render/LICENSES.md`。

**图表为什么被删掉。** Mermaid（5.4 MB）与 ECharts（1.1 MB）随包发了一个版本，
而 `MdView` 把每个 `Chart` 块都画成「图表渲染未接入」占位卡片——两个引擎一次都
没执行过，却占了 HAP 的 60%。现在 ` ```mermaid ` 就是普通围栏代码块，按 mermaid
语法高亮成源码，这比一张承诺以后会渲染的卡片诚实。要加回图表：先试自研极简流程图
（`graph TD` + 方框箭头，几百行 ArkUI），或在真机上验证 tree-shaken 的 Mermaid
子集再谈预算——不要把全量包重新塞回来。

> **不要引入 PlantUML。** 上游是 GPL，与本项目的授权不兼容。

## 1. 数据模型

`MdTypes.ets` 是唯一来源，字段与语义见该文件的注释。要点：

- 块级是**一维数组**。层级靠 `indent`（列表缩进）与 `quoteDepth`（引用层数）
  两个**正交**字段，不要合并。
- 行内是**一维数组 + 样式标志位**（`bold`/`italic`/`strike`/`code`），
  不建父子树。解析期就完成切分。
- `srcLine` 是块首行在原文中的行号（**0 起**），块级编辑与任务勾选回写靠它。
- `emptyBlock()` / `emptyInline()` / `emptyParseResult()` 是组件参数默认值，
  不要在 ArkTS 里出现未初始化成员。

## 2. `MdParser.ets`

```ts
export class MdParser {
  /** 主入口。绝不抛异常：畸形输入降级成段落，返回可渲染的结果。 */
  static parse(source: string): MdParseResult;

  /** 行内解析。表格单元格、标题、列表项内部复用它。 */
  static inlineOf(text: string, bold?: boolean, italic?: boolean): MdInline[];

  /** 行内片段拼回纯文本（目录、摘要、无障碍）。 */
  static plainOf(inlines: MdInline[]): string;

  /** 块在原文中的行区间 [start, end)，0 起左闭右开。 */
  static srcRangeOf(blocks: MdBlock[], index: number): MdSrcRange;

  /** 预处理：CRLF→LF、Tab→4 空格、去掉 BOM。 */
  static normalize(source: string): string;
}
```

`MdSrcRange` 是 `{ start: number; end: number }`，从 `MdTypes.ets` 导出。

### 必须支持的块级语法

1. ATX 标题 `#`…`######`，`#` 后必须有空格；`#######` 不算标题。
2. 段落，段内软换行连成一行；行尾两个空格 → 硬换行。
3. 围栏代码 ````` ``` ````/`~~~`，语言名、以及 ` ```lang{1,3-5} ` 形式的行号高亮。
   围栏闭合缺失时吃到文末，不吞异常。
4. 引用 `>`，可嵌套（`>>` → `quoteDepth = 2`）。引用内部的段落/列表照常识别。
5. GFM 提示块 `> [!NOTE]` / `TIP` / `IMPORTANT` / `WARNING` / `CAUTION`，
   **类型名必须全大写**，且 `[!类型]` 后必须换行；`> [!note]` 按普通引用处理。
6. 无序列表 `-` `*` `+`，有序列表 `1.` `1)`，缩进 **≥2 空格**算嵌套一层。
   有序列表的起始序号写进 `seq`。
7. 任务列表 `- [ ]` / `- [x]`（`- [X]` 也认）。
8. 表格：表头行 + 分隔行（`| --- | :---: | ---: |`）**必须有分隔行**，
   缺了整块按段落渲染。列对齐进 `aligns`。单元格里的 `\|` 是转义的竖线。
9. 分割线 `---` / `***` / `___`（≥3 个）。**紧跟在文字行下面的 `---` 是标题下划线**，
   不是分割线——这个判定顺序不能错。
10. 公式块 `$$…$$`（独立成段）。
11. 图表块**不存在**。围栏语言名不再分叉，` ```mermaid ` 与 ` ```echarts ` 都是
    普通 `MdBlockKind.Code`（`lang` 保留，按该语言高亮成源码）。
12. 脚注定义 `[^label]: 内容` 收进 `notes`，正文里 `[^label]` 是
    `MdInlineKind.FootnoteRef`（`text` = label，`num` = 序号，0 表示引用存在但缺定义）。
    **不要**把它降级成 `Link`——脚注引用要渲染成上标序号并跳到注释区，
    与普通链接的外观和交互都不同。
13. YAML front matter（文件首行 `---` 到下一个 `---`）**跳过**，不进正文、不计数。
    纸见自己用 `services/Frontmatter.ets` 解析它，解析器只需不要把它当分割线。

### 必须支持的行内语法

`` ` `` 行内代码、`**`/`__` 粗体、`*`/`_` 斜体、`***` 粗斜体、`~~` 删除线、
`==` 高亮、`[文字](地址)` 链接、`![alt](地址)` 图片、`$…$` 行内公式、
`^上标^`、`~下标~`、`\` 转义（`` \`*_{}[]()#+-.!|~ ``）。

**配对规则**：符号内侧不能贴空格（`** 粗 **` 不生效）、不能跨空行配对、
数量必须对称（`**粗*` 整行不加粗）。

### 渲染层的硬性约定（解析侧必须配合）

- **行内图片不进 `Span`**：只有**独立成段**的 `![]()` 才算图片块；
  与文字混排的图片退化成替代文本。原因是 `Span` 里塞图会破坏逐字坐标系，
  而文本选择/批注都建立在那个坐标系上。
- 段落 `plain` 必须是行内文本拼回去的结果，不是原文行。

## 3. `CodeHighlight.ets`

```ts
export enum CodeTokenStyle {
  Plain = 0, Keyword = 1, Str = 2, Num = 3, Comment = 4,
  Func = 5, Type = 6, Punct = 7, Tag = 8, Attr = 9, Meta = 10
}

export interface CodeToken {
  text: string;
  style: CodeTokenStyle;
}

export class CodeHighlight {
  /** 整段代码 → 逐行 token。行数必须与入参行数一致。 */
  static tokenizeLines(lines: string[], lang: string): CodeToken[][];
  /** 语言是否高亮。false 时调用方直接画纯文本，不要走分词。 */
  static supports(lang: string): boolean;
}
```

按**语言族**扫描，不是按语言逐个写：`cLike`（js/ts/java/c/cpp/cs/go/rust/
kotlin/swift/php/scss…）、`hash`（py/rb/sh/yaml/toml/ini/dockerfile…）、
`markup`（html/xml/svg/vue…）、`css`、`sql`、`data`（json/json5）、`diff`。

实现约束：
- **多行注释与多行字符串必须跨行维持状态**（`/* … */`、Python 三引号）。
  只逐行独立扫描会让第二行开始的注释变成正文。
- **所有前进游标的循环必须保证游标推进**。历史上一个 `\frac25` 式的解析
  死循环把整个应用卡死过。任何 `while` 里都要有「无论如何 +1」的兜底。
- 未识别语言 → `supports()` 返回 false，调用方画纯文本。**不要**猜语言。
- 不许 `any`、不许索引签名。token 用 `CodeToken` 接口。

## 4. `MdView.ets`

```ts
@ComponentV2
export struct MdBlockView {
  @Param block: MdBlock = emptyBlock();
  @Param bodySize: number = 17;      // 正文字号 px
  @Param lineHeight: number = 1.75;
  @Param dark: boolean = false;
  @Param accent: string = '#0A59F7';
  @Param onLink: (href: string) => void = () => {};
  @Param onTaskToggle: (block: MdBlock) => void = () => {};
}
```

外加一个 `MdDocumentView`（`@ComponentV2`），接收 `@Param blocks: MdBlock[]`，
内部 `ForEach(this.blocks, ...)` 逐块渲染，key 用 `block.id`。

渲染约定：
- 正文行内**必须** `Text() { ForEach(this.block.inlines, ...) { Span(...) } }`。
  嵌套 `Text` 会在 `ForEach` 分支重置父级样式追踪。
- 颜色/字号/圆角全部来自 `$r('app.color.*')` 或 `@Param`，不写死。
- 代码块：`Text` 每行一个，行内 `ForEach(tokens) { Span }` 上色；
  横向可滚动（`Scroll` + `.scrollable(ScrollDirection.Horizontal)`），不要换行。
- 表格：列多时横向滚动；单元格不能换行。
- 块级公式 `$$…$$`：`MdView.MathBlock()` → `components/FormulaWeb.ets` →
  `rawfile/render/katex.html`，KaTeX 量到高度后回报，失败时退回
  `MathLite.linearize()` 的 Unicode 文本，永远不留空白块。
- 行内 `$…$`：`MdView.textFor()` 用 `MathLite` 线性化成正文（`E = mc²`），
  不加代码底色——它读起来是散文，不是源码。
- 图表：**没有图表块**，围栏按普通代码块高亮。

## 5. 验证

`tools/md-parse-check.js`（Node）加载一份语料，断言：

- 块数量与类型顺序
- 每块的 `plain` 文本
- 列表的 `indent` / 有序性 / `seq`
- 表格的 `aligns` 与格数
- 代码块的 `lang` / `code` / `hlLines`
- `outline` 的层级与序号
- 解析 10 万字文档的耗时（不得出现明显卡顿，目标 < 150 ms）

语料 `tools/corpus/*.md` 覆盖上面第 2 节列的每一条，**每条至少一个反例**
（`#标题` 不算标题、`| --- |` 缺失的表格、不收口的围栏、`> [!note]` 小写）。
