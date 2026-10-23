/**
 * 纸见 · Markdown 解析器
 * ======================
 *
 * 契约见 `docs/markdown-engine.md` §2。本文件只做**一件事**：把 Markdown 原文切成
 * `MdTypes.ets` 定义的那套扁平 AST（块级一维数组 + 行内一维数组 + 样式标志位），
 * 不做任何布局、颜色、字号决定。
 *
 * ## 为什么不引第三方库
 *
 * ArkTS 严格模式禁掉了 `any`、索引签名、`Function.apply/call`，绝大多数 JS 版
 * Markdown 解析器在编译这一步就过不去；强行套 `interface {}` 只会把类型错误
 * 推到运行时。自研的成本是一个文件，收益是「任何畸形输入都降级成段落」这件事
 * 可以被逐条验证。
 *
 * ## 三条铁律
 *
 * 1. **绝不抛异常。** `parse()` 整体包在 `try/catch` 里，每个块解析器自己也不
 *    假定输入合法。一个畸形的围栏不能把整篇文章变成白屏。
 * 2. **每个 `while` 必须保证游标推进。** 块级主循环除了每个分支各自推进之外，
 *    循环末尾还有一道 `if (i <= start) i = start + 1` 兜底；行内扫描里每个
 *    `continue` 之前都改了 `i`。历史上一个不推进的游标把整个应用卡死过。
 * 3. **宁可当文本，不要误切。** 任何含糊的构造（缺分隔行的表格、配对数量不对称的
 *    强调、没闭合的围栏）都退回段落，而不是猜一个「更聪明」的结构——解析器
 *    把一段正文切成两半，比少支持一个扩展语法糟糕得多。
 *
 * ## 顺序敏感的两处（改之前先读）
 *
 * - **`---` 紧跟文字行 = setext 标题下划线，不是分割线。** 判定发生在
 *   `parseParagraph()` 内部：段落在往下吞行时先看下一行是不是 setext 下划线，
 *   是就收成一个标题块。主循环里的 `isDivider()` 只在「当前行不是任何构造的开头」
 *   时才会轮到，所以 `text\n---` 永远到不了分割线分支。
 * - **表格必须有分隔行。** `isTableStart()` 要求下一行是 `| --- | :---: |` 形态，
 *   且列数与表头一致；`| a | b |` 下面直接跟 `| 1 | 2 |` 会走段落分支。
 *
 * ## 几个刻意的取舍（渲染侧需要知道）
 *
 * - **脚注引用**：正文里的 `[^label]` 产出 `MdInlineKind.FootnoteRef`，
 *   `text` = label、`num` = 定义序号（缺定义为 0）。渲染侧按 `num > 0` 决定
 *   是否渲染成上标序号，`num === 0` 说明引用存在但文末没有定义。
 * - **独立成段的图片**：`MdBlockKind` 里没有 Image 块，所以整段只有一个 `![]()`
 *   时仍然是一个 `Paragraph`，其 `inlines` 只有一个 `MdInlineKind.Image`，
 *   `plain` 是 alt 文本。渲染侧可以按「单 Image 行内 + 段落」判断成图。
 * - **硬换行**用行内文本里的 `\n` 字符表达（AST 没有 Break 种类）。软换行连成一个
 *   空格。
 * - **脚注定义**也产出一个 `Paragraph`（否则 `MdNote.blockIndex` 无处指），
 *   `plain` 是定义内容本身。
 * - **多行段落里的缩进续行**并入当前列表项的行内文本；列表项内部的代码块/表格
 *   不识别（只会当成续行文本）。这是保守取舍：误识别会在列表里凭空长出块。
 */

import {
  MdBlock,
  MdBlockKind,
  MdCalloutKind,
  MdHeading,
  MdInline,
  MdInlineKind,
  MdNote,
  MdParseResult,
  MdSrcRange,
  MdTableRow,
  MdTaskState,
  emptyBlock,
  emptyInline,
  emptyParseResult,
  isChartLang
} from './MdTypes';

/**
 * 反斜杠可转义的字符集（与 `docs/markdown-engine.md` §2 一致）。
 *
 * 不在这个集合里的字符，反斜杠原样保留——`\d` 在正则、`C:\Users` 在正文里都很常见，
 * 把反斜杠吃掉会让用户以为自己写错了。
 */
const ESCAPABLE: string = '\\`*_{}[]()#+-.!|~';

/** 行内强调 / 删除线 / 高亮等符号的最大运行长度（`***` 是上限）。 */
const MAX_MARKER_RUN: number = 3;

/** 解析过程中跨函数共享的游标状态。 */
class ParseCtx {
  blocks: MdBlock[] = [];
  outline: MdHeading[] = [];
  noteRecs: NoteRec[] = [];
  noteIndex: Map<string, number> = new Map<string, number>();
  headingSeq: number = 0;
}

/** 脚注定义的中间记录：定义先扫描、正文解析时回填 blockIndex。 */
class NoteRec {
  label: string = '';
  no: number = 0;
  body: string = '';
  srcLine: number = 0;
  blockIndex: number = -1;
}

/** 围栏信息。 */
class FenceInfo {
  ch: string = '`';
  len: number = 3;
  info: string = '';
}

/** 围栏语言名 + 行号高亮。 */
class FenceSpec {
  lang: string = '';
  hl: number[] = [];
}

/** 列表标记。 */
class ListMarker {
  indentSpaces: number = 0;
  marker: string = '';
  ordered: boolean = false;
  seq: number = 0;
  content: string = '';
  contentIndent: number = 0;
}

/** 任务勾选状态。 */
class TaskInfo {
  state: MdTaskState = MdTaskState.None;
  text: string = '';
}

/** `[文字](地址)` / `![alt](地址)` 的切分结果。 */
class LinkParts {
  label: string = '';
  href: string = '';
  next: number = 0;
}

/** `## 标题 {#anchor}` 的切分结果。 */
class AnchorInfo {
  id: string = '';
  text: string = '';
}

/** 字数统计结果。 */
class Counts {
  chars: number = 0;
  words: number = 0;
}

/**
 * 当前解析会话的「脚注 label → 序号」表。
 *
 * `inlineOf()` 的公开签名由契约固定（三个参数），没法再传一张表进去，所以用模块级
 * 变量承载。`parse()` 进出各设一次，单线程 UI 调用下安全；直接调 `inlineOf()`
 * 的人看到的是空表（`num = 0`），符合「引用缺定义」的语义。
 */
let ACTIVE_LABELS: Map<string, number> = new Map<string, number>();

// ---------------------------------------------------------------------------
// 字符级工具
// ---------------------------------------------------------------------------

function isSpaceChar(c: string): boolean {
  if (c.length === 0) {
    return false;
  }
  return c === ' ' || c === '\t' || c === '\n' || c === '\r';
}

function isAsciiWordChar(c: string): boolean {
  if (c.length === 0) {
    return false;
  }
  const code = c.charCodeAt(0);
  const digit = code >= 48 && code <= 57;
  const upper = code >= 65 && code <= 90;
  const lower = code >= 97 && code <= 122;
  return digit || upper || lower;
}

function isBlankLine(line: string): boolean {
  for (let i = 0; i < line.length; i++) {
    if (!isSpaceChar(line.charAt(i))) {
      return false;
    }
  }
  return true;
}

function leadingSpaceCount(line: string): number {
  let n = 0;
  while (n < line.length && line.charAt(n) === ' ') {
    n++;
  }
  return n;
}

function endsWithTwoSpaces(line: string): boolean {
  if (line.length < 2) {
    return false;
  }
  return line.charAt(line.length - 1) === ' ' && line.charAt(line.length - 2) === ' ';
}

function runLength(text: string, at: number, ch: string): number {
  let n = 0;
  while (at + n < text.length && text.charAt(at + n) === ch) {
    n++;
  }
  return n;
}

/** 纯数字串 → 数值；含非数字返回 -1（不用 `parseInt`，避免实现差异）。 */
function toInt(s: string): number {
  if (s.length === 0) {
    return -1;
  }
  let n = 0;
  for (let i = 0; i < s.length; i++) {
    const code = s.charCodeAt(i);
    if (code < 48 || code > 57) {
      return -1;
    }
    n = n * 10 + (code - 48);
    if (n > 100000000) {
      return -1;
    }
  }
  return n;
}

// ---------------------------------------------------------------------------
// 行扫描：引用 / 围栏 / 标题 / 分割线 / 列表 / 表格
// ---------------------------------------------------------------------------

function isQuoteLine(line: string): boolean {
  const sp = leadingSpaceCount(line);
  if (sp > 3) {
    return false;
  }
  return sp < line.length && line.charAt(sp) === '>';
}

/** 去掉**一层**引用标记 `>` 及其后的一个空格。 */
function stripQuoteMarker(line: string): string {
  let i = leadingSpaceCount(line);
  if (i > 3) {
    i = 0;
  }
  if (i < line.length && line.charAt(i) === '>') {
    i++;
    if (i < line.length && line.charAt(i) === ' ') {
      i++;
    }
  }
  return line.substring(i);
}

/** 去掉所有层的引用标记（提示块正文里用）。 */
function stripAllQuoteMarkers(line: string): string {
  let cur = line;
  let guard = 0;
  while (guard < 64) {
    guard++;
    if (!isQuoteLine(cur)) {
      return cur;
    }
    cur = stripQuoteMarker(cur);
  }
  return cur;
}

function fenceStart(line: string): FenceInfo | null {
  const sp = leadingSpaceCount(line);
  if (sp > 3) {
    return null;
  }
  if (sp >= line.length) {
    return null;
  }
  const ch = line.charAt(sp);
  if (ch !== '`' && ch !== '~') {
    return null;
  }
  const len = runLength(line, sp, ch);
  if (len < 3) {
    return null;
  }
  const info = line.substring(sp + len).trim();
  if (ch === '`' && info.indexOf('`') >= 0) {
    return null;
  }
  const f = new FenceInfo();
  f.ch = ch;
  f.len = len;
  f.info = info;
  return f;
}

function isFenceClose(line: string, f: FenceInfo): boolean {
  const sp = leadingSpaceCount(line);
  if (sp > 3) {
    return false;
  }
  if (sp >= line.length || line.charAt(sp) !== f.ch) {
    return false;
  }
  const len = runLength(line, sp, f.ch);
  if (len < f.len) {
    return false;
  }
  return isBlankLine(line.substring(sp + len));
}

/**
 * ATX 标题层级；0 = 不是标题。
 *
 * `#标题` 不算（`#` 后必须有空格或行尾），`#######` 不算（先把整段 `#` 数完再判范围，
 * 不能靠正则回溯成 6 个）。
 */
function atxLevel(line: string): number {
  const sp = leadingSpaceCount(line);
  if (sp > 3) {
    return 0;
  }
  let n = 0;
  while (sp + n < line.length && line.charAt(sp + n) === '#') {
    n++;
  }
  if (n < 1 || n > 6) {
    return 0;
  }
  if (sp + n >= line.length) {
    return n;
  }
  if (line.charAt(sp + n) !== ' ') {
    return 0;
  }
  return n;
}

/** 去掉前导 `#` 与可选的收尾 `#` 序列。 */
function atxContent(line: string, level: number): string {
  const sp = leadingSpaceCount(line);
  let text = line.substring(sp + level).trim();
  let end = text.length;
  while (end > 0 && text.charAt(end - 1) === '#') {
    end--;
  }
  if (end < text.length) {
    if (end === 0) {
      text = '';
    } else if (text.charAt(end - 1) === ' ') {
      text = text.substring(0, end).trim();
    }
  }
  return text;
}

/**
 * setext 下划线层级：`===` → 1，`---` → 2，其他 → 0。
 *
 * `-` 要求 **≥3 个**（比 CommonMark 的「≥1」更严）：单个 `-` 紧跟文字行时，
 * 判成标题下划线会把一个本来只是「空列表项」的行升级成标题，代价比少支持一次
 * 单横线标题大得多。
 */
function setextUnderlineLevel(line: string): number {
  const sp = leadingSpaceCount(line);
  if (sp > 3) {
    return 0;
  }
  const t = line.trim();
  if (t.length === 0) {
    return 0;
  }
  const ch = t.charAt(0);
  if (ch !== '=' && ch !== '-') {
    return 0;
  }
  for (let i = 0; i < t.length; i++) {
    if (t.charAt(i) !== ch) {
      return 0;
    }
  }
  if (ch === '=') {
    return 1;
  }
  return t.length >= 3 ? 2 : 0;
}

function isDivider(line: string): boolean {
  const sp = leadingSpaceCount(line);
  if (sp > 3) {
    return false;
  }
  const t = line.trim();
  if (t.length < 3) {
    return false;
  }
  const ch = t.charAt(0);
  if (ch !== '-' && ch !== '*' && ch !== '_') {
    return false;
  }
  let count = 0;
  for (let i = 0; i < t.length; i++) {
    const c = t.charAt(i);
    if (c === ch) {
      count++;
    } else if (c === ' ' || c === '\t') {
      continue;
    } else {
      return false;
    }
  }
  return count >= 3;
}

function listMarkerOf(line: string): ListMarker | null {
  const sp = leadingSpaceCount(line);
  if (sp > 24) {
    return null;
  }
  if (sp >= line.length) {
    return null;
  }
  const ch = line.charAt(sp);
  let marker = '';
  let ordered = false;
  let seq = 0;
  let p = sp;
  if (ch === '-' || ch === '*' || ch === '+') {
    marker = ch;
    p++;
  } else if (ch >= '0' && ch <= '9') {
    let q = p;
    while (q < line.length && line.charAt(q) >= '0' && line.charAt(q) <= '9') {
      q++;
    }
    if (q - p > 9) {
      return null;
    }
    if (q >= line.length) {
      return null;
    }
    const dot = line.charAt(q);
    if (dot !== '.' && dot !== ')') {
      return null;
    }
    marker = line.substring(p, q + 1);
    seq = toInt(line.substring(p, q));
    if (seq < 0) {
      return null;
    }
    ordered = true;
    p = q + 1;
  } else {
    return null;
  }
  if (p < line.length) {
    const sep = line.charAt(p);
    if (sep !== ' ' && sep !== '\t') {
      return null;
    }
  }
  let contentIndent = p;
  while (contentIndent < line.length && line.charAt(contentIndent) === ' ') {
    contentIndent++;
  }
  const content = contentIndent < line.length ? line.substring(contentIndent) : '';
  const m = new ListMarker();
  m.indentSpaces = sp;
  m.marker = marker;
  m.ordered = ordered;
  m.seq = ordered ? seq : 0;
  m.content = content;
  m.contentIndent = contentIndent;
  return m;
}

/** `- [ ] 文本` / `- [x] 文本`。 */
function taskOf(text: string): TaskInfo {
  const info = new TaskInfo();
  info.text = text;
  if (text.length < 3) {
    return info;
  }
  if (text.charAt(0) !== '[' || text.charAt(2) !== ']') {
    return info;
  }
  const mark = text.charAt(1);
  if (mark !== ' ' && mark !== 'x' && mark !== 'X') {
    return info;
  }
  if (text.length > 3 && text.charAt(3) !== ' ') {
    return info;
  }
  if (mark === ' ') {
    info.state = MdTaskState.Todo;
  } else {
    info.state = MdTaskState.Done;
  }
  info.text = text.length > 3 ? text.substring(4).trim() : '';
  return info;
}

function isFootnoteDefLine(line: string): boolean {
  return footnoteLabelOf(line).length > 0;
}

/** `[^label]:` 的 label；不是定义返回空串。 */
function footnoteLabelOf(line: string): string {
  const sp = leadingSpaceCount(line);
  if (sp > 3) {
    return '';
  }
  if (sp + 3 >= line.length) {
    return '';
  }
  if (line.charAt(sp) !== '[' || line.charAt(sp + 1) !== '^') {
    return '';
  }
  const close = line.indexOf(']', sp + 2);
  if (close < 0) {
    return '';
  }
  if (close + 1 >= line.length || line.charAt(close + 1) !== ':') {
    return '';
  }
  const label = line.substring(sp + 2, close).trim();
  return label;
}

// ---------------------------------------------------------------------------
// 表格
// ---------------------------------------------------------------------------

function endsWithEscapedPipe(s: string): boolean {
  if (s.length === 0 || s.charAt(s.length - 1) !== '|') {
    return false;
  }
  let n = 0;
  let k = s.length - 2;
  while (k >= 0 && s.charAt(k) === '\\') {
    n++;
    k--;
  }
  return n % 2 === 1;
}

/**
 * 按**未转义**的 `|` 切单元格。
 *
 * `\|` 原样保留（连反斜杠一起），交给行内解析去还原——这样表格单元格里的
 * `\|` 与正文里其他位置的转义规则完全一致。
 */
function splitCells(line: string): string[] {
  let s = line.trim();
  if (s.length > 0 && s.charAt(0) === '|') {
    s = s.substring(1);
  }
  if (s.length > 0 && s.charAt(s.length - 1) === '|' && !endsWithEscapedPipe(s)) {
    s = s.substring(0, s.length - 1);
  }
  const cells: string[] = [];
  let cur = '';
  let i = 0;
  while (i < s.length) {
    const c = s.charAt(i);
    if (c === '\\' && i + 1 < s.length) {
      cur += c;
      cur += s.charAt(i + 1);
      i += 2;
      continue;
    }
    if (c === '|') {
      cells.push(cur);
      cur = '';
      i++;
      continue;
    }
    cur += c;
    i++;
  }
  cells.push(cur);
  const out: string[] = [];
  for (const cell of cells) {
    out.push(cell.trim());
  }
  return out;
}

/** 分隔行单元格：`---` / `:---` / `---:` / `:---:`。 */
function isDelimiterCell(text: string): boolean {
  let s = text.trim();
  if (s.length === 0) {
    return false;
  }
  if (s.charAt(0) === ':') {
    s = s.substring(1);
  }
  if (s.length > 0 && s.charAt(s.length - 1) === ':') {
    s = s.substring(0, s.length - 1);
  }
  if (s.length === 0) {
    return false;
  }
  for (let i = 0; i < s.length; i++) {
    if (s.charAt(i) !== '-') {
      return false;
    }
  }
  return true;
}

function alignOf(text: string): number {
  const t = text.trim();
  const left = t.length > 0 && t.charAt(0) === ':';
  const right = t.length > 1 && t.charAt(t.length - 1) === ':';
  if (left && right) {
    return 1;
  }
  if (right) {
    return 2;
  }
  return 0;
}

function isTableStart(lines: string[], idx: number, to: number): boolean {
  if (idx + 1 >= to) {
    return false;
  }
  const head = lines[idx];
  if (isBlankLine(head)) {
    return false;
  }
  if (head.indexOf('|') < 0) {
    return false;
  }
  const delim = lines[idx + 1];
  if (delim.indexOf('-') < 0) {
    return false;
  }
  const delimCells = splitCells(delim);
  if (delimCells.length === 0) {
    return false;
  }
  for (const cell of delimCells) {
    if (!isDelimiterCell(cell)) {
      return false;
    }
  }
  const headCells = splitCells(head);
  return headCells.length === delimCells.length;
}

// ---------------------------------------------------------------------------
// 行内解析
// ---------------------------------------------------------------------------

function appendInline(out: MdInline[], kind: MdInlineKind, text: string, href: string, num: number,
  bold: boolean, italic: boolean, strike: boolean, code: boolean): void {
  const item = emptyInline();
  item.kind = kind;
  item.text = text;
  item.href = href;
  item.num = num;
  item.bold = bold;
  item.italic = italic;
  item.strike = strike;
  item.code = code;
  out.push(item);
}

function pushAll(out: MdInline[], items: MdInline[]): void {
  for (const item of items) {
    out.push(item);
  }
}

/**
 * 把「只含一个纯文本片段」的强调结果升级成对应的语义种类。
 *
 * 扁平 + 标志位是主模型（见 `MdTypes.ets` 文件头），所以 `**粗**` 解析出来本来就是
 * `Plain{text:'粗', bold:true}`。但 `MdInlineKind` 里仍然有 `Strong`/`Em`/`Strike`
 * 三个值，渲染方很可能按种类分支；单一文本时顺手打上种类，两种读法都能正确渲染，
 * 代价是零。**含嵌套片段时不打**——那时其中一个 span 是粗、另一个还叠了斜体，
 * 用种类表达不了，只能靠标志位。
 */
function tagSingle(sub: MdInline[], kind: MdInlineKind): void {
  if (sub.length === 1 && sub[0].kind === MdInlineKind.Plain && sub[0].text.length > 0) {
    sub[0].kind = kind;
  }
}

/**
 * 找配对的收尾符号。
 *
 * 三条配对规则都落在这里：收尾符号前面不能是空白（`** 粗 **` 不生效）、
 * 不能跨空行（遇到 `\n\n` 直接放弃）、数量必须与开启处相等（`run === want`，
 * 所以 `**粗*` 里的单个 `*` 不会被当成 `**` 的收尾）。
 */
function findCloser(text: string, from: number, ch: string, want: number, wordRule: boolean): number {
  let k = from;
  while (k < text.length) {
    const c = text.charAt(k);
    if (c === '\\') {
      k += 2;
      continue;
    }
    if (c === '\n') {
      if (k + 1 < text.length && text.charAt(k + 1) === '\n') {
        return -1;
      }
      k++;
      continue;
    }
    if (c !== ch) {
      k++;
      continue;
    }
    const run = runLength(text, k, ch);
    if (run === want && k > from) {
      const before = text.charAt(k - 1);
      const afterIdx = k + run;
      const after = afterIdx < text.length ? text.charAt(afterIdx) : '';
      if (!isSpaceChar(before)) {
        if (!wordRule || after.length === 0 || !isAsciiWordChar(after)) {
          return k;
        }
      }
    }
    k += run;
  }
  return -1;
}

function parseLinkAt(text: string, open: number): LinkParts | null {
  if (open >= text.length || text.charAt(open) !== '[') {
    return null;
  }
  let depth = 0;
  let close = -1;
  let k = open;
  while (k < text.length) {
    const c = text.charAt(k);
    if (c === '\\') {
      k += 2;
      continue;
    }
    if (c === '[') {
      depth++;
    } else if (c === ']') {
      depth--;
      if (depth <= 0) {
        close = k;
        break;
      }
    }
    k++;
  }
  if (close < 0) {
    return null;
  }
  if (close + 1 >= text.length || text.charAt(close + 1) !== '(') {
    return null;
  }
  let pd = 0;
  let pclose = -1;
  let q = close + 1;
  while (q < text.length) {
    const c = text.charAt(q);
    if (c === '\\') {
      q += 2;
      continue;
    }
    if (c === '(') {
      pd++;
    } else if (c === ')') {
      pd--;
      if (pd <= 0) {
        pclose = q;
        break;
      }
    }
    q++;
  }
  if (pclose < 0) {
    return null;
  }
  const label = text.substring(open + 1, close);
  let href = text.substring(close + 2, pclose).trim();
  if (href.length >= 2 && href.charAt(0) === '<' && href.charAt(href.length - 1) === '>') {
    href = href.substring(1, href.length - 1).trim();
  }
  const sp = href.indexOf(' ');
  if (sp > 0) {
    href = href.substring(0, sp);
  }
  if (href.length === 0) {
    return null;
  }
  const parts = new LinkParts();
  parts.label = label;
  parts.href = href;
  parts.next = pclose + 1;
  return parts;
}

function inlineScan(text: string, bold: boolean, italic: boolean, strike: boolean, out: MdInline[]): void {
  let i = 0;
  let plain = '';
  const flush = (): void => {
    if (plain.length > 0) {
      appendInline(out, MdInlineKind.Plain, plain, '', 0, bold, italic, strike, false);
      plain = '';
    }
  };
  while (i < text.length) {
    const ch = text.charAt(i);

    // --- 转义 ---
    if (ch === '\\') {
      if (i + 1 < text.length && ESCAPABLE.indexOf(text.charAt(i + 1)) >= 0) {
        plain += text.charAt(i + 1);
        i += 2;
      } else {
        plain += '\\';
        i++;
      }
      continue;
    }

    // --- 行内代码 ---
    if (ch === '`') {
      const run = runLength(text, i, '`');
      let k = i + run;
      let close = -1;
      while (k < text.length) {
        if (text.charAt(k) === '`') {
          const r = runLength(text, k, '`');
          if (r === run) {
            close = k;
            break;
          }
          k += r;
        } else {
          k++;
        }
      }
      if (close < 0) {
        plain += text.substring(i, i + run);
        i += run;
        continue;
      }
      let inner = text.substring(i + run, close);
      if (inner.length > 2 && inner.charAt(0) === ' ' && inner.charAt(inner.length - 1) === ' ') {
        inner = inner.substring(1, inner.length - 1);
      }
      flush();
      appendInline(out, MdInlineKind.Code, inner, '', 0, bold, italic, strike, true);
      i = close + run;
      continue;
    }

    // --- 粗体 / 斜体 ---
    if (ch === '*' || ch === '_') {
      const run = runLength(text, i, ch);
      if (run <= MAX_MARKER_RUN) {
        const want = run;
        const openEnd = i + want;
        const wordRule = ch === '_';
        let mayOpen = openEnd < text.length && !isSpaceChar(text.charAt(openEnd));
        if (mayOpen && wordRule && i > 0 && isAsciiWordChar(text.charAt(i - 1))) {
          mayOpen = false;
        }
        if (mayOpen) {
          const closePos = findCloser(text, openEnd, ch, want, wordRule);
          if (closePos >= 0) {
            flush();
            const nb = bold || want >= 2;
            const ni = italic || want === 1 || want === 3;
            const sub: MdInline[] = [];
            inlineScan(text.substring(openEnd, closePos), nb, ni, strike, sub);
            tagSingle(sub, want === 1 ? MdInlineKind.Em : MdInlineKind.Strong);
            pushAll(out, sub);
            i = closePos + want;
            continue;
          }
        }
      }
      plain += text.substring(i, i + run);
      i += run;
      continue;
    }

    // --- 删除线 / 下标 ---
    if (ch === '~') {
      const run = runLength(text, i, '~');
      if (run >= 2) {
        const openEnd = i + 2;
        if (openEnd < text.length && !isSpaceChar(text.charAt(openEnd))) {
          const closePos = findCloser(text, openEnd, '~', 2, false);
          if (closePos >= 0) {
            flush();
            const sub: MdInline[] = [];
            inlineScan(text.substring(openEnd, closePos), bold, italic, true, sub);
            tagSingle(sub, MdInlineKind.Strike);
            pushAll(out, sub);
            i = closePos + 2;
            continue;
          }
        }
      }
      if (run === 1 && i + 1 < text.length && !isSpaceChar(text.charAt(i + 1))) {
        const closePos = findCloser(text, i + 1, '~', 1, false);
        if (closePos > i + 1) {
          flush();
          appendInline(out, MdInlineKind.Sub, text.substring(i + 1, closePos), '', 0, bold, italic, strike, false);
          i = closePos + 1;
          continue;
        }
      }
      plain += text.substring(i, i + run);
      i += run;
      continue;
    }

    // --- 高亮 ---
    if (ch === '=') {
      const run = runLength(text, i, '=');
      if (run === 2) {
        const openEnd = i + 2;
        if (openEnd < text.length && !isSpaceChar(text.charAt(openEnd))) {
          const closePos = findCloser(text, openEnd, '=', 2, false);
          if (closePos >= 0) {
            flush();
            appendInline(out, MdInlineKind.Mark, text.substring(openEnd, closePos), '', 0, bold, italic, strike, false);
            i = closePos + 2;
            continue;
          }
        }
      }
      plain += text.substring(i, i + run);
      i += run;
      continue;
    }

    // --- 上标 ---
    if (ch === '^') {
      const run = runLength(text, i, '^');
      if (run === 1 && i + 1 < text.length && !isSpaceChar(text.charAt(i + 1))) {
        const closePos = findCloser(text, i + 1, '^', 1, false);
        if (closePos > i + 1) {
          flush();
          appendInline(out, MdInlineKind.Sup, text.substring(i + 1, closePos), '', 0, bold, italic, strike, false);
          i = closePos + 1;
          continue;
        }
      }
      plain += text.substring(i, i + run);
      i += run;
      continue;
    }

    // --- 行内公式 ---
    if (ch === '$') {
      const run = runLength(text, i, '$');
      if (run === 1) {
        const close = text.indexOf('$', i + 1);
        if (close > i + 1) {
          const inner = text.substring(i + 1, close);
          const okOpen = !isSpaceChar(inner.charAt(0));
          const okClose = !isSpaceChar(inner.charAt(inner.length - 1));
          if (okOpen && okClose && inner.indexOf('\n') < 0) {
            flush();
            appendInline(out, MdInlineKind.MathInline, inner, '', 0, bold, italic, strike, false);
            i = close + 1;
            continue;
          }
        }
      }
      plain += text.substring(i, i + run);
      i += run;
      continue;
    }

    // --- 脚注引用 ---
    if (ch === '[' && i + 1 < text.length && text.charAt(i + 1) === '^') {
      const close = text.indexOf(']', i + 2);
      if (close > i + 2) {
        const label = text.substring(i + 2, close);
        const resolved = ACTIVE_LABELS.get(label);
        const num = resolved === undefined ? 0 : resolved;
        flush();
        appendInline(out, MdInlineKind.FootnoteRef, label, '', num, bold, italic, strike, false);
        i = close + 1;
        continue;
      }
    }

    // --- 链接 / 图片 ---
    if (ch === '[') {
      const parts = parseLinkAt(text, i);
      if (parts !== null) {
        flush();
        const innerText = MdParser.plainOf(MdParser.inlineOf(parts.label, bold, italic));
        appendInline(out, MdInlineKind.Link, innerText, parts.href, 0, bold, italic, strike, false);
        i = parts.next;
        continue;
      }
      plain += '[';
      i++;
      continue;
    }
    if (ch === '!') {
      if (i + 1 < text.length && text.charAt(i + 1) === '[') {
        const parts = parseLinkAt(text, i + 1);
        if (parts !== null) {
          flush();
          const alt = MdParser.plainOf(MdParser.inlineOf(parts.label, bold, italic));
          appendInline(out, MdInlineKind.Image, alt, parts.href, 0, bold, italic, strike, false);
          i = parts.next;
          continue;
        }
      }
      plain += '!';
      i++;
      continue;
    }

    plain += ch;
    i++;
  }
  flush();
}

// ---------------------------------------------------------------------------
// 块级：工具
// ---------------------------------------------------------------------------

function newBlock(ctx: ParseCtx): MdBlock {
  const b = emptyBlock();
  b.id = '' + ctx.blocks.length;
  return b;
}

/**
 * 把若干行拼成一段行内文本：软换行连成一个空格，行尾两个空格（或空行）→ `\n`。
 */
function joinRegionLines(lines: string[]): string {
  let out = '';
  let has = false;
  let breakNext = false;
  for (let k = 0; k < lines.length; k++) {
    const raw = lines[k];
    if (isBlankLine(raw)) {
      breakNext = true;
      continue;
    }
    const body = raw.trim();
    if (!has) {
      out = body;
      has = true;
    } else if (breakNext) {
      out += '\n';
      out += body;
    } else {
      out += ' ';
      out += body;
    }
    breakNext = endsWithTwoSpaces(raw);
  }
  return out;
}

function anchorOf(text: string): AnchorInfo | null {
  const t = text.trim();
  if (t.length < 4 || t.charAt(t.length - 1) !== '}') {
    return null;
  }
  const open = t.lastIndexOf('{#');
  if (open < 0) {
    return null;
  }
  const id = t.substring(open + 2, t.length - 1).trim();
  if (id.length === 0) {
    return null;
  }
  for (let i = 0; i < id.length; i++) {
    const c = id.charAt(i);
    const ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
      c === '-' || c === '_' || c === '.' || c === ':';
    if (!ok) {
      return null;
    }
  }
  const info = new AnchorInfo();
  info.id = id;
  info.text = t.substring(0, open).trim();
  return info;
}

function pushHeading(ctx: ParseCtx, rawText: string, level: number, srcLine: number, quoteDepth: number): void {
  let text = rawText;
  let anchor = '';
  const info = anchorOf(text);
  if (info !== null) {
    anchor = info.id;
    text = info.text;
  }
  const b = newBlock(ctx);
  b.kind = MdBlockKind.Heading;
  b.level = level;
  ctx.headingSeq++;
  b.headingSeq = ctx.headingSeq;
  b.srcLine = srcLine;
  b.quoteDepth = quoteDepth;
  b.inlines = MdParser.inlineOf(text);
  degradeImages(b.inlines);
  b.plain = MdParser.plainOf(b.inlines);
  if (anchor.length > 0) {
    b.anchor = anchor;
  }
  ctx.blocks.push(b);
  const h: MdHeading = {
    level: level,
    text: b.plain,
    blockIndex: ctx.blocks.length - 1,
    seq: b.headingSeq,
    anchor: anchor
  };
  ctx.outline.push(h);
}

/**
 * 行内图片降级成替代文本（`MdInlineKind.Image` → `Plain`）。
 *
 * 契约（`docs/markdown-engine.md` §2 渲染层约定）：**只有独立成段的 `![]()` 才算
 * 图片块**，与文字混排的图片退化成 alt 文本。原因是 `Span` 里塞图会破坏逐字坐标系，
 * 而文本选择与批注都建立在那之上。这条在解析侧执行，因为只有解析侧知道「这一段
 * 是不是只有一张图」。
 */
function degradeImages(inlines: MdInline[]): void {
  for (const item of inlines) {
    if (item.kind === MdInlineKind.Image) {
      item.kind = MdInlineKind.Plain;
      item.href = '';
    }
  }
}

/** 这一段是否「只有一张图」（纯空白片段不算内容）。 */
function isSoleImage(inlines: MdInline[]): boolean {
  let count = 0;
  let onlyImage = true;
  for (const item of inlines) {
    if (item.text.trim().length === 0) {
      continue;
    }
    count++;
    if (item.kind !== MdInlineKind.Image) {
      onlyImage = false;
    }
  }
  return count === 1 && onlyImage;
}

function pushParagraph(ctx: ParseCtx, text: string, srcLine: number, quoteDepth: number): void {
  const b = newBlock(ctx);
  b.kind = MdBlockKind.Paragraph;
  b.srcLine = srcLine;
  b.quoteDepth = quoteDepth;
  b.inlines = MdParser.inlineOf(text);
  if (!isSoleImage(b.inlines)) {
    degradeImages(b.inlines);
  }
  b.plain = MdParser.plainOf(b.inlines);
  ctx.blocks.push(b);
}

/** 下一行是否开启一个新块（用于结束段落 / 列表续行）。 */
function startsBlock(lines: string[], idx: number, to: number): boolean {
  const line = lines[idx];
  if (isBlankLine(line)) {
    return true;
  }
  if (fenceStart(line) !== null) {
    return true;
  }
  if (atxLevel(line) > 0) {
    return true;
  }
  if (isQuoteLine(line)) {
    return true;
  }
  if (isDivider(line)) {
    return true;
  }
  if (isMathStart(line)) {
    return true;
  }
  if (isFootnoteDefLine(line)) {
    return true;
  }
  if (listMarkerOf(line) !== null) {
    return true;
  }
  return isTableStart(lines, idx, to);
}

function isMathStart(line: string): boolean {
  const t = line.trim();
  return t.length >= 2 && t.charAt(0) === '$' && t.charAt(1) === '$';
}

function fenceSpecOf(info: string): FenceSpec {
  const spec = new FenceSpec();
  if (info.length === 0) {
    return spec;
  }
  let token = info;
  const sp = info.indexOf(' ');
  if (sp > 0) {
    token = info.substring(0, sp);
  }
  let name = token;
  if (token.length > 2 && token.charAt(token.length - 1) === '}') {
    const open = token.indexOf('{');
    if (open > 0) {
      name = token.substring(0, open);
      spec.hl = parseRanges(token.substring(open + 1, token.length - 1));
    } else if (open === 0) {
      name = '';
      spec.hl = parseRanges(token.substring(1, token.length - 1));
    }
  }
  spec.lang = name.trim().toLowerCase();
  return spec;
}

function parseRanges(body: string): number[] {
  const out: number[] = [];
  const parts = body.split(',');
  for (const part of parts) {
    if (out.length > 2000) {
      break;
    }
    const t = part.trim();
    if (t.length === 0) {
      continue;
    }
    const dash = t.indexOf('-');
    if (dash > 0) {
      const a = toInt(t.substring(0, dash).trim());
      const b = toInt(t.substring(dash + 1).trim());
      if (a >= 1 && b >= a) {
        const hi = Math.min(b, a + 500);
        for (let v = a; v <= hi; v++) {
          out.push(v);
        }
      }
    } else {
      const a = toInt(t);
      if (a >= 1) {
        out.push(a);
      }
    }
  }
  return out;
}

function calloutKindOf(text: string): MdCalloutKind {
  if (text === '[!NOTE]') {
    return MdCalloutKind.Note;
  }
  if (text === '[!TIP]') {
    return MdCalloutKind.Tip;
  }
  if (text === '[!IMPORTANT]') {
    return MdCalloutKind.Important;
  }
  if (text === '[!WARNING]') {
    return MdCalloutKind.Warning;
  }
  if (text === '[!CAUTION]') {
    return MdCalloutKind.Caution;
  }
  return MdCalloutKind.None;
}

// ---------------------------------------------------------------------------
// 块级：各构造
// ---------------------------------------------------------------------------

function emitDivider(ctx: ParseCtx, srcLine: number, quoteDepth: number): void {
  const b = newBlock(ctx);
  b.kind = MdBlockKind.Divider;
  b.srcLine = srcLine;
  b.quoteDepth = quoteDepth;
  ctx.blocks.push(b);
}

function parseAtx(lines: string[], src: number[], start: number, quoteDepth: number, ctx: ParseCtx): number {
  const line = lines[start];
  const level = atxLevel(line);
  if (level <= 0) {
    return start + 1;
  }
  pushHeading(ctx, atxContent(line, level), level, src[start], quoteDepth);
  return start + 1;
}

/** 围栏代码 / 图表。未闭合时吃到区域末尾，照样产出 Code 块。 */
function parseFence(lines: string[], src: number[], start: number, to: number,
  quoteDepth: number, ctx: ParseCtx): number {
  const f = fenceStart(lines[start]);
  if (f === null) {
    return start + 1;
  }
  const body: string[] = [];
  let i = start + 1;
  while (i < to) {
    if (isFenceClose(lines[i], f)) {
      i++;
      break;
    }
    body.push(lines[i]);
    i++;
  }
  const spec = fenceSpecOf(f.info);
  const b = newBlock(ctx);
  b.kind = isChartLang(spec.lang) ? MdBlockKind.Chart : MdBlockKind.Code;
  b.lang = spec.lang;
  b.codeLines = body;
  b.code = body.join('\n');
  b.srcLine = src[start];
  b.quoteDepth = quoteDepth;
  if (spec.hl.length > 0) {
    b.hlLines = spec.hl;
  }
  ctx.blocks.push(b);
  return i;
}

function parseMath(lines: string[], src: number[], start: number, to: number,
  quoteDepth: number, ctx: ParseCtx): number {
  const t = lines[start].trim();
  const body: string[] = [];
  let i = start + 1;
  if (t.length > 2 && t.endsWith('$$')) {
    body.push(t.substring(2, t.length - 2).trim());
  } else {
    body.push(t.substring(2));
    let closed = false;
    while (i < to) {
      const raw = lines[i];
      const rt = raw.trim();
      i++;
      if (rt.endsWith('$$')) {
        body.push(rt.substring(0, rt.length - 2));
        closed = true;
        break;
      }
      body.push(raw);
    }
    if (!closed) {
      // 未闭合：保持到区域末尾，内容照原样收进来，不吞掉后面的文本。
    }
  }
  while (body.length > 0 && body[0].trim().length === 0) {
    body.shift();
  }
  while (body.length > 0 && body[body.length - 1].trim().length === 0) {
    body.pop();
  }
  const b = newBlock(ctx);
  b.kind = MdBlockKind.Math;
  b.code = body.join('\n');
  b.codeLines = body;
  b.srcLine = src[start];
  b.quoteDepth = quoteDepth;
  ctx.blocks.push(b);
  return i;
}

function parseFootnoteDef(lines: string[], src: number[], start: number, to: number, ctx: ParseCtx): number {
  const label = footnoteLabelOf(lines[start]);
  if (label.length === 0) {
    return start + 1;
  }
  const line = lines[start];
  const sp = leadingSpaceCount(line);
  const close = line.indexOf(']', sp + 2);
  const parts: string[] = [];
  const firstPart = close + 2 <= line.length ? line.substring(close + 2).trim() : '';
  parts.push(firstPart);
  let i = start + 1;
  while (i < to) {
    const raw = lines[i];
    if (isBlankLine(raw)) {
      break;
    }
    if (leadingSpaceCount(raw) < 2) {
      break;
    }
    if (startsBlock(lines, i, to) && !isBlankLine(raw)) {
      break;
    }
    parts.push(raw);
    i++;
  }
  const text = joinRegionLines(parts);
  const recIdx = ctx.noteIndex.get(label);
  let rec: NoteRec;
  if (recIdx === undefined) {
    rec = new NoteRec();
    rec.label = label;
    rec.no = ctx.noteRecs.length + 1;
    rec.srcLine = src[start];
    ctx.noteIndex.set(label, ctx.noteRecs.length);
    ctx.noteRecs.push(rec);
  } else {
    rec = ctx.noteRecs[recIdx];
  }
  rec.body = text;
  pushParagraph(ctx, text, src[start], 0);
  rec.blockIndex = ctx.blocks.length - 1;
  return i;
}

function parseTable(lines: string[], src: number[], start: number, to: number,
  quoteDepth: number, ctx: ParseCtx): number {
  const headCells = splitCells(lines[start]);
  const delimCells = splitCells(lines[start + 1]);
  const colCount = headCells.length;
  const aligns: number[] = [];
  for (const cell of delimCells) {
    aligns.push(alignOf(cell));
  }
  const rows: MdTableRow[] = [];
  rows.push(makeTableRow(headCells, true, colCount));
  let i = start + 2;
  while (i < to) {
    const raw = lines[i];
    if (isBlankLine(raw) || raw.indexOf('|') < 0) {
      break;
    }
    if (startsBlock(lines, i, to)) {
      break;
    }
    rows.push(makeTableRow(splitCells(raw), false, colCount));
    i++;
  }
  const b = newBlock(ctx);
  b.kind = MdBlockKind.Table;
  b.rows = rows;
  b.aligns = aligns;
  b.srcLine = src[start];
  b.quoteDepth = quoteDepth;
  const plainParts: string[] = [];
  for (const row of rows) {
    for (let c = 0; c < row.cells.length; c++) {
      const cellText = MdParser.plainOf(row.cells[c]);
      if (cellText.length > 0) {
        plainParts.push(cellText);
      }
    }
  }
  b.plain = plainParts.join(' ');
  ctx.blocks.push(b);
  return i;
}

function makeTableRow(cells: string[], header: boolean, colCount: number): MdTableRow {
  const raw: string[] = [];
  const parsed: MdInline[][] = [];
  for (let k = 0; k < colCount; k++) {
    const text = k < cells.length ? cells[k] : '';
    raw.push(text);
    const cellInlines = MdParser.inlineOf(text);
    degradeImages(cellInlines);
    parsed.push(cellInlines);
  }
  const row: MdTableRow = { raw: raw, cells: parsed, header: header };
  return row;
}

/**
 * 引用 / 提示块。
 *
 * 切出连续的 `>` 行，再判断首行是不是 `[!TYPE]`：**类型必须全大写、必须整行只有它、
 * 后面必须有内容行**。否则按普通引用递归解析——`> [!note]` 应该原样显示成 `[!note]`。
 *
 * **空行结束引用。** 引用内部的空行必须写成 `>`（`>` 后面没内容 = 空行），这是
 * CommonMark 的口径，也是这里唯一安全的读法：如果让空行后面还能续上下一段 `>`，
 * 紧跟在引用后面的 `> [!NOTE]` 就会被吞进上一段引用当正文，提示块直接消失。
 */
function parseQuote(lines: string[], src: number[], start: number, to: number,
  quoteDepth: number, ctx: ParseCtx): number {
  const sub: string[] = [];
  const subSrc: number[] = [];
  let i = start;
  while (i < to) {
    const raw = lines[i];
    if (!isQuoteLine(raw)) {
      break;
    }
    sub.push(stripQuoteMarker(raw));
    subSrc.push(src[i]);
    i++;
  }
  if (sub.length === 0) {
    return start + 1;
  }
  const depth = quoteDepth + 1;
  const kind = calloutKindOf(sub[0].trim());
  if (kind !== MdCalloutKind.None && sub.length >= 2) {
    const bodyLines: string[] = [];
    for (let k = 1; k < sub.length; k++) {
      bodyLines.push(stripAllQuoteMarkers(sub[k]));
    }
    const text = joinRegionLines(bodyLines);
    const b = newBlock(ctx);
    b.kind = MdBlockKind.Callout;
    b.callout = kind;
    b.quoteDepth = depth;
    b.srcLine = src[start];
    b.inlines = MdParser.inlineOf(text);
    degradeImages(b.inlines);
    b.plain = MdParser.plainOf(b.inlines);
    ctx.blocks.push(b);
    return i;
  }
  parseRegion(sub, subSrc, 0, sub.length, depth, ctx);
  return i;
}

function parseList(lines: string[], src: number[], start: number, to: number,
  quoteDepth: number, ctx: ParseCtx): number {
  let i = start;
  while (i < to) {
    if (isDivider(lines[i])) {
      break;
    }
    const mk = listMarkerOf(lines[i]);
    if (mk === null) {
      break;
    }
    const itemStart = i;
    const parts: string[] = [mk.content];
    i++;
    while (i < to) {
      const raw = lines[i];
      if (isBlankLine(raw)) {
        let j = i + 1;
        while (j < to && isBlankLine(lines[j])) {
          j++;
        }
        if (j < to && leadingSpaceCount(lines[j]) >= mk.indentSpaces + 2) {
          i = j;
          continue;
        }
        break;
      }
      if (isDivider(raw)) {
        break;
      }
      if (listMarkerOf(raw) !== null) {
        break;
      }
      if (leadingSpaceCount(raw) >= mk.indentSpaces + 2) {
        parts.push(raw);
        i++;
        continue;
      }
      break;
    }

    const joined = joinRegionLines(parts);
    const task = taskOf(joined);
    const b = newBlock(ctx);
    b.kind = MdBlockKind.ListItem;
    b.indent = Math.floor(mk.indentSpaces / 2);
    b.ordered = mk.ordered;
    b.seq = mk.ordered ? mk.seq : 0;
    b.marker = mk.marker;
    b.task = task.state;
    b.quoteDepth = quoteDepth;
    b.srcLine = src[itemStart];
    b.inlines = MdParser.inlineOf(task.text);
    degradeImages(b.inlines);
    b.plain = MdParser.plainOf(b.inlines);
    ctx.blocks.push(b);

    if (i < to && isBlankLine(lines[i])) {
      let j = i;
      while (j < to && isBlankLine(lines[j])) {
        j++;
      }
      if (j < to && listMarkerOf(lines[j]) !== null && !isDivider(lines[j])) {
        i = j;
        continue;
      }
      break;
    }
    if (i < to && listMarkerOf(lines[i]) !== null && !isDivider(lines[i])) {
      continue;
    }
    break;
  }
  return i > start ? i : start + 1;
}

/**
 * 段落，以及 setext 标题。
 *
 * **顺序敏感**：段落往下吞行时，先看下一行是不是 `===` / `---` 下划线，是就收成
 * 标题；再看不看得成一个新块。反过来（先判分割线）会让 `Title\n---` 变成
 * 「一段文字 + 一条分割线」。
 */
function parseParagraph(lines: string[], src: number[], start: number, to: number,
  quoteDepth: number, ctx: ParseCtx): number {
  const buf: string[] = [];
  let i = start;
  let setext = 0;
  while (i < to) {
    const raw = lines[i];
    if (isBlankLine(raw)) {
      break;
    }
    if (buf.length > 0) {
      const lvl = setextUnderlineLevel(raw);
      if (lvl > 0) {
        setext = lvl;
        i++;
        break;
      }
      if (startsBlock(lines, i, to)) {
        break;
      }
    }
    buf.push(raw);
    i++;
  }
  if (buf.length === 0) {
    return start + 1;
  }
  const text = joinRegionLines(buf);
  if (setext > 0) {
    pushHeading(ctx, text, setext, src[start], quoteDepth);
  } else {
    pushParagraph(ctx, text, src[start], quoteDepth);
  }
  return i;
}

function parseRegion(lines: string[], src: number[], from: number, to: number,
  quoteDepth: number, ctx: ParseCtx): void {
  let i = from;
  let iterations = 0;
  while (i < to) {
    iterations++;
    if (iterations > 1000000) {
      break;
    }
    const start = i;
    const line = lines[start];
    if (isBlankLine(line)) {
      i = start + 1;
    } else if (isQuoteLine(line)) {
      i = parseQuote(lines, src, start, to, quoteDepth, ctx);
    } else if (fenceStart(line) !== null) {
      i = parseFence(lines, src, start, to, quoteDepth, ctx);
    } else if (atxLevel(line) > 0) {
      i = parseAtx(lines, src, start, quoteDepth, ctx);
    } else if (isMathStart(line)) {
      i = parseMath(lines, src, start, to, quoteDepth, ctx);
    } else if (isFootnoteDefLine(line)) {
      i = parseFootnoteDef(lines, src, start, to, ctx);
    } else if (isTableStart(lines, start, to)) {
      i = parseTable(lines, src, start, to, quoteDepth, ctx);
    } else if (isDivider(line)) {
      emitDivider(ctx, src[start], quoteDepth);
      i = start + 1;
    } else if (listMarkerOf(line) !== null) {
      i = parseList(lines, src, start, to, quoteDepth, ctx);
    } else {
      i = parseParagraph(lines, src, start, to, quoteDepth, ctx);
    }
    // 兜底：任何分支算出的下一个游标没有前进，都必须强制前进一行。
    if (i <= start) {
      i = start + 1;
    }
  }
}

// ---------------------------------------------------------------------------
// 统计
// ---------------------------------------------------------------------------

function isCjkCode(code: number): boolean {
  if (code >= 0x4E00 && code <= 0x9FFF) {
    return true;
  }
  if (code >= 0x3400 && code <= 0x4DBF) {
    return true;
  }
  if (code >= 0x3040 && code <= 0x30FF) {
    return true;
  }
  if (code >= 0xAC00 && code <= 0xD7AF) {
    return true;
  }
  return code >= 0xF900 && code <= 0xFAFF;
}

/**
 * 字符数（不含空白）与字数（中日韩按字、西文按词）。
 *
 * 代码块 / 图表块 / 分割线不计入：它们不是「读的字」。
 */
function countOf(blocks: MdBlock[]): Counts {
  const counts = new Counts();
  for (const b of blocks) {
    if (b.kind === MdBlockKind.Code || b.kind === MdBlockKind.Chart || b.kind === MdBlockKind.Divider) {
      continue;
    }
    const text = b.plain;
    let inWord = false;
    for (let k = 0; k < text.length; k++) {
      const code = text.charCodeAt(k);
      const ch = text.charAt(k);
      if (isSpaceChar(ch)) {
        inWord = false;
        continue;
      }
      counts.chars++;
      if (isCjkCode(code)) {
        counts.words++;
        inWord = false;
        continue;
      }
      if (isAsciiWordChar(ch)) {
        if (!inWord) {
          counts.words++;
          inWord = true;
        }
        continue;
      }
      inWord = false;
    }
  }
  return counts;
}

// ---------------------------------------------------------------------------
// 公开入口
// ---------------------------------------------------------------------------

export class MdParser {
  /**
   * 主入口。**绝不抛异常**：畸形输入降级成段落，返回可渲染的结果。
   *
   * 调用顺序有意义：先 `normalize()`（CRLF / Tab / BOM），再按 `\n` 切行——
   * 之后所有 `srcLine` 都是**归一化后**文本的 0 起行号，块级回写必须以这份文本为基准。
   */
  static parse(source: string): MdParseResult {
    try {
      const text = MdParser.normalize(source);
      const lines = text.split('\n');
      // 文末的换行会切出一个幽灵空行：不摘掉它，未闭合围栏的 `code` 会平白多一个
      // 尾换行，最后一段的 `plain` 也会多一次拼接机会。只摘一个——真的空行要留着。
      if (lines.length > 0 && lines[lines.length - 1] === '') {
        lines.pop();
      }
      const ctx = new ParseCtx();

      // --- 1. YAML front matter：文件首行 `---` 到下一个 `---`，整段跳过 ---
      let bodyStart = 0;
      if (lines.length > 0 && lines[0].trim() === '---') {
        for (let k = 1; k < lines.length; k++) {
          if (lines[k].trim() === '---') {
            bodyStart = k + 1;
            break;
          }
        }
      }

      // --- 2. 脚注定义先扫一遍，正文里的 `[^label]` 才能拿到序号 ---
      for (let k = bodyStart; k < lines.length; k++) {
        const label = footnoteLabelOf(lines[k]);
        if (label.length === 0) {
          continue;
        }
        if (ctx.noteIndex.get(label) === undefined) {
          const rec = new NoteRec();
          rec.label = label;
          rec.no = ctx.noteRecs.length + 1;
          rec.srcLine = k;
          ctx.noteIndex.set(label, ctx.noteRecs.length);
          ctx.noteRecs.push(rec);
        }
      }

      // --- 3. 正文 ---
      const src: number[] = [];
      for (let k = 0; k < lines.length; k++) {
        src.push(k);
      }
      ACTIVE_LABELS = ctx.noteIndex;
      parseRegion(lines, src, bodyStart, lines.length, 0, ctx);

      // --- 4. 组装结果 ---
      const notes: MdNote[] = [];
      for (const rec of ctx.noteRecs) {
        const note: MdNote = {
          no: rec.no,
          label: rec.label,
          text: rec.body,
          inlines: MdParser.inlineOf(rec.body),
          blockIndex: rec.blockIndex
        };
        notes.push(note);
      }
      const counts = countOf(ctx.blocks);
      const result = emptyParseResult();
      result.blocks = ctx.blocks;
      result.outline = ctx.outline;
      result.notes = notes;
      result.footnoteCount = notes.length;
      result.headingCount = ctx.outline.length;
      let codeCount = 0;
      let tableCount = 0;
      for (const b of ctx.blocks) {
        if (b.kind === MdBlockKind.Code) {
          codeCount++;
        } else if (b.kind === MdBlockKind.Table) {
          tableCount++;
        }
      }
      result.codeBlockCount = codeCount;
      result.tableCount = tableCount;
      result.charCount = counts.chars;
      result.wordCount = counts.words;
      ACTIVE_LABELS = new Map<string, number>();
      return result;
    } catch (error) {
      ACTIVE_LABELS = new Map<string, number>();
      return emptyParseResult();
    }
  }

  /**
   * 行内解析。表格单元格、标题、列表项内部复用它。
   *
   * `bold` / `italic` 是**继承标志**：嵌套强调时递归传入，切分完的每个片段都带
   * 完整的样式状态，渲染侧不需要还原父子关系。
   */
  static inlineOf(text: string, bold?: boolean, italic?: boolean): MdInline[] {
    const out: MdInline[] = [];
    const isBold = bold === true;
    const isItalic = italic === true;
    try {
      inlineScan(text, isBold, isItalic, false, out);
      return out;
    } catch (error) {
      const fallback: MdInline[] = [];
      appendInline(fallback, MdInlineKind.Plain, text, '', 0, isBold, isItalic, false, false);
      return fallback;
    }
  }

  /** 行内片段拼回纯文本（目录、摘要、无障碍、字数统计）。 */
  static plainOf(inlines: MdInline[]): string {
    let out = '';
    for (const item of inlines) {
      out += item.text;
    }
    return out;
  }

  /**
   * 块在原文中的行区间 `[start, end)`，0 起左闭右开。
   *
   * `end` 取下一个块的 `srcLine`——Markdown 的块在原文里连续且有序，
   * 所以块的结束行只能这样推断。越界时返回 `{0, 0}`，不抛异常。
   */
  static srcRangeOf(blocks: MdBlock[], index: number, totalLines: number = 0): MdSrcRange {
    if (index < 0 || index >= blocks.length) {
      const empty: MdSrcRange = { start: 0, end: 0 };
      return empty;
    }
    const start = blocks[index].srcLine;
    let end = start + 1;
    if (index + 1 < blocks.length) {
      const next = blocks[index + 1].srcLine;
      if (next > start) {
        end = next;
      }
    } else if (totalLines > start) {
      // 最后一个块没有「下一块」可以借位，必须由调用方给出总行数，
      // 否则一个多行的末块只会被截到首行——编辑时把后面几行留在原地，
      // 写回后变成两个块。
      end = totalLines;
    }
    const range: MdSrcRange = { start: start, end: end };
    return range;
  }

  /** 预处理：去掉 BOM、CRLF→LF、Tab→4 空格。 */
  static normalize(source: string): string {
    let s = source;
    if (s.length > 0 && s.charCodeAt(0) === 0xFEFF) {
      s = s.substring(1);
    }
    s = s.replace(/\r\n/g, '\n');
    s = s.replace(/\r/g, '\n');
    s = s.replace(/\t/g, '    ');
    return s;
  }
}
