/**
 * 纸见 · Markdown 抽象语法树（AST）类型
 * =========================================
 *
 * 本文件是解析层与渲染层之间**唯一的数据契约**。改字段要全局搜。
 *
 * ## 为什么是扁平数组，不是嵌套树
 *
 * ArkUI 的自定义组件不能递归引用自身，`@Builder` 的递归渲染在 ArkTS 的
 * 严格模式下限制更多。所以块级用**一维数组**，层级用字段表达：
 * 列表缩进 → `indent`，引用嵌套 → `quoteDepth`。渲染侧一次 `ForEach` 即可，
 * 不需要递归，也不会踩「自定义组件不能自引用」的坑。
 *
 * ## 行内为什么是标志位，不是嵌套节点
 *
 * `**粗体里的 \`代码\`**` 如果建成父子树，渲染就要递归；改成「每个片段带上
 * 从外层继承下来的样式标志位」，解析结果是两个平级片段、都带 `bold`，
 * 渲染侧同样一次 `ForEach`。
 *
 * 这条设计直接决定渲染写法：正文行内富文本**必须**写成
 * `Text() { ForEach(...) { Span(...) } }`。嵌套 `Text` 会让编译器在
 * `ForEach` 分支里重置父组件追踪，样式继承随之断裂。
 */

/** 块级元素种类 */
export enum MdBlockKind {
  Heading = 0,
  Paragraph = 1,
  Code = 2,
  Quote = 3,
  ListItem = 4,
  Table = 5,
  Divider = 6,
  Callout = 7,
  /** 数学公式块（`$$…$$`），由 KaTeX 渲染；图未就绪时退回 `MathLite` 线性化文本 */
  Math = 8
}

/** 行内片段种类 */
export enum MdInlineKind {
  Plain = 0,
  Strong = 1,
  Em = 2,
  Code = 3,
  Strike = 4,
  Link = 5,
  Image = 6,
  /** 高亮 `==文字==`（扩展语法） */
  Mark = 7,
  /** 行内数学 `$…$`，KaTeX 渲染成图内联 */
  MathInline = 8,
  /** 上标 `^文字^` */
  Sup = 9,
  /** 下标 `~文字~` */
  Sub = 10,
  /**
   * 脚注引用 `[^label]`。与 `Link` 分开是必要的：脚注引用要渲染成**上标序号**
   * 并跳到注释区，而普通链接是行内文字 + 强调色，两者外观与交互都不同。
   * `text` 存 label，`num` 存序号（0 = 引用存在但缺定义）。
   */
  FootnoteRef = 11
}

/** GFM 提示块种类（`> [!NOTE]` 这类写法） */
export enum MdCalloutKind {
  None = 0,
  Note = 1,
  Tip = 2,
  Important = 3,
  Warning = 4,
  Caution = 5
}

/** 列表项任务状态 */
export enum MdTaskState {
  None = -1,
  Todo = 0,
  Done = 1
}

/**
 * 行内片段。
 *
 * 样式用**标志位**表达继承关系而不是嵌套结构，见文件头。
 * `bold`/`italic`/`strike`/`code` 是「这个片段整体是否生效」，
 * 不是「这里开始了一个粗体」——切分在解析期就做完了。
 */
export interface MdInline {
  kind: MdInlineKind;
  /** 显示文本（脚注引用时为 label） */
  text: string;
  /** 链接 / 图片地址；非链接类为空串 */
  href: string;
  /** 脚注序号（1 起；0 表示引用缺定义） */
  num: number;
  bold: boolean;
  italic: boolean;
  strike: boolean;
  code: boolean;
  /**
   * 相对字号（1 = 正文字号）。`<small>` 这类只改大小的写法用。
   * 未设 = 跟随正文。渲染端乘在 bodySize 上。
   */
  size?: number;
}

/** 表格行 */
export interface MdTableRow {
  /** 每格的**原始 Markdown 文本**，渲染时再解析行内 */
  raw: string[];
  /** 每格解析后的行内片段 */
  cells: MdInline[][];
  /** 是否表头行 */
  header: boolean;
}

/** 块级元素 */
export interface MdBlock {
  /** 稳定 key（块序号，字符串形式） */
  id: string;
  kind: MdBlockKind;
  /**
   * 显式锚点（`## 标题 {#intro}` 里的 `intro`）。无则 undefined。
   * 让 `[文字](#intro)` 能精确命中，而不是靠标题文字模糊匹配。
   */
  anchor?: string;

  // ---- 标题 ----
  /** 标题层级 1–6；非标题为 0 */
  level: number;
  /** 标题序号（1 起，按出现顺序；非标题为 0） */
  headingSeq: number;

  // ---- 代码 / 图表 ----
  /** 围栏语言名，小写化；无则空串 */
  lang: string;
  /** 代码块 / 图表块的原始文本（图表块就是那段图定义源码） */
  code: string;
  /** 代码块按行切开，供逐行渲染与行号 */
  codeLines: string[];
  /** 需要额外高亮的行号（围栏元数据 ```lang{1,3-5}），1 起 */
  hlLines?: number[];

  // ---- 行内内容 ----
  /** 段落 / 标题 / 引用 / 列表项 / 提示块正文的行内片段 */
  inlines: MdInline[];
  /** 纯文本（字数统计、目录、无障碍用） */
  plain: string;

  // ---- 列表 ----
  /** 缩进层级（0 起）。顶层列表项为 0 */
  indent: number;
  /** 有序列表 */
  ordered: boolean;
  /** 有序列表的序号（渲染 `3.` 这类自定义起点）；无序为 0 */
  seq: number;
  /** 列表标记原文（`-`、`*`、`1.` 等） */
  marker: string;
  /** 任务状态 */
  task: MdTaskState;

  // ---- 引用 ----
  /**
   * 引用嵌套深度（0 = 不在引用里，1 = `>`，2 = `>>`）。
   * 与 `indent` 分开：列表缩进和引用层数是两个正交的维度，
   * 合成一个字段会让「引用里的列表」无法表达。
   */
  quoteDepth: number;

  // ---- 表格 ----
  rows: MdTableRow[];
  /** 每列对齐：0 左 1 中 2 右 */
  aligns: number[];

  // ---- 提示块 ----
  callout: MdCalloutKind;

  // ---- 源定位 ----
  /**
   * 该块首行在原文中的行号（**0 起**）。
   *
   * 块级实时编辑与任务勾选回写都靠它定位源文本：块上只记起始行，结束行用
   * 「下一个块的起始行」推断——Markdown 的块在原文里连续且有序，这个推断成立。
   */
  srcLine: number;
}

/** 目录条目 */
export interface MdHeading {
  level: number;
  text: string;
  /** 在 blocks 数组中的下标，用于跳转 */
  blockIndex: number;
  /** 标题序号 */
  seq: number;
  /** 显式锚点；无则空串 */
  anchor: string;
}

/**
 * 注释（脚注）条目。
 *
 * 脚注不是「附加物」而是第二正文：阅读页用它在注释抽屉里渲染注释卡，
 * 点击可跳回正文对应位置。
 */
export interface MdNote {
  /** 序号（1 起） */
  no: number;
  /** 原始 label（`[^label]` 里的 label） */
  label: string;
  /** 纯文本 */
  text: string;
  /** 行内片段，注释卡内渲染富文本用 */
  inlines: MdInline[];
  /** 注释块在 blocks 中的下标，用于跳转 */
  blockIndex: number;
}

/** 解析结果 */
export interface MdParseResult {
  blocks: MdBlock[];
  outline: MdHeading[];
  notes: MdNote[];
  /** 脚注条数 */
  footnoteCount: number;
  /** 标题数 */
  headingCount: number;
  /** 代码块数 */
  codeBlockCount: number;
  /** 表格数 */
  tableCount: number;
  /** 字符数（不含空白） */
  charCount: number;
  /** 字数（中日韩按字计，西文按词计） */
  wordCount: number;
}

/** 空块：仅用作组件参数的默认值，避免 ArkTS 里出现未初始化成员。 */
export function emptyBlock(): MdBlock {
  const block: MdBlock = {
    id: '0',
    kind: MdBlockKind.Paragraph,
    level: 0,
    headingSeq: 0,
    lang: '',
    code: '',
    codeLines: [],
    inlines: [],
    plain: '',
    indent: 0,
    ordered: false,
    seq: 0,
    marker: '',
    task: MdTaskState.None,
    quoteDepth: 0,
    rows: [],
    aligns: [],
    callout: MdCalloutKind.None,
    srcLine: 0
  };
  return block;
}

/** 空行内片段。 */
export function emptyInline(): MdInline {
  const item: MdInline = {
    kind: MdInlineKind.Plain,
    text: '',
    href: '',
    num: 0,
    bold: false,
    italic: false,
    strike: false,
    code: false
  };
  return item;
}

/**
 * 「图表块」这一档已经移除，围栏一律当普通代码块。
 *
 * 曾经 ` ```mermaid ` / ` ```echarts ` 会被识别成独立的 `Chart` 块，交给 ArkWeb
 * 里的 Mermaid / ECharts 渲染。但 `MdView` 从头到尾只把它画成一张「图表渲染未
 * 接入」的占位卡片——两个库（合计 6.5 MB）在包里躺了一个版本，一次都没执行过。
 *
 * 现在这些围栏按普通代码块处理：` ```mermaid ` 会以 mermaid 语法高亮成一屏源码。
 * 这比一张永远写着「未接入」的卡片诚实，也顺手删掉了两个跑不到的引擎。
 */

/**
 * 空解析结果。`parse()` 失败时返回它而不是抛异常——
 * 渲染层拿到的必须是可用对象，否则一篇文章里一个畸形围栏就整页白屏。
 */
/**
 * 块在原文中的行区间，**0 起、左闭右开**。
 *
 * 由 `MdParser.srcRangeOf()` 产出：`start` 是块首行的行号（等于 `block.srcLine`），
 * `end` 是**下一个块**的首行行号（最后一块则为 `start + 1`）。Markdown 的块在原文里
 * 连续且有序，所以块的结束行只能靠下一个块推断——这也是 `MdBlock` 只记 `srcLine`
 * 的原因。块级编辑把这个区间回写成新文本时，不要把 `end` 当成「块最后一行 + 1」以外
 * 的东西：中间的空行属于前一个块。
 */
export interface MdSrcRange {
  start: number;
  end: number;
}

export function emptyParseResult(): MdParseResult {
  const result: MdParseResult = {
    blocks: [],
    outline: [],
    notes: [],
    footnoteCount: 0,
    headingCount: 0,
    codeBlockCount: 0,
    tableCount: 0,
    charCount: 0,
    wordCount: 0
  };
  return result;
}
