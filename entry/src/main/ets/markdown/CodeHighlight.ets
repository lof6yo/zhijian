/**
 * 纸见 · 代码块语法着色（自研分词器）
 * ==================================
 *
 * 只做一件事：把一段代码**逐行**切成带样式的 token。解析器不认识语言，
 * 渲染器也不认识语言，只有这里认识。
 *
 * ## 一条不可破的不变式
 *
 *     对任意一行：tokens.map(t => t.text).join('') === 原文行
 *
 * 也就是说这里做的是「切分」，不是「改写」。颜色错了只是难看；拼接对不上，
 * 代码块显示的就是**另一段代码**，用户复制走的是他没写过的东西。所以本文件
 * 里没有任何一个字符可以被丢弃：
 *   - 每条分支要么推进游标并输出，要么落到循环末尾 `pushToken(out, c); i++` 的兜底；
 *   - `while (i < n)` 里每一个 `continue` 都保证 `i` 严格增大；
 *   - `substring` 的区间首尾相接，不重叠、不留缝。
 * 改这个文件时先看这三条，再动别的。
 *
 * 空行返回**空数组**（不是 `[{ text: '', … }]`），调用方据此画一条零宽行。
 *
 * ## 为什么按「语言族」扫描，不按语言逐个写
 *
 * 高亮只要「看起来对」，不需要语法分析。js/ts/java/go/rust 的注释、字符串、
 * 数字、标点规则几乎一致，写 40 份只会有 40 处逐渐走样。所以归并成七族：
 *
 *   cLike  —— js jsx ts tsx java c h cpp cs go rust kotlin swift php scala
 *             dart objective-c m mm scss less groovy
 *   hash   —— py rb sh bash zsh yaml toml ini conf dockerfile makefile r perl
 *             ps1 nginx apache cmake gitignore
 *   markup —— html xml svg vue svelte hbs handlebars xaml
 *   css    —— css
 *   sql    —— sql mysql postgresql sqlite plsql
 *   data   —— json json5 jsonc geojson
 *   diff   —— diff patch
 *
 * 族内关键字取并集：`int` 在 js 里不会被用到，多认一个词的代价是零。
 *
 * ## 跨行状态
 *
 * C 风格块注释、Python 三引号、Go 反引号 / Rust 原始串、JS 模板串、HTML
 * 注释都可能跨行。逐行独立扫描会让第二行起整段变成正文——这是这类分词器最
 * 常见的错，所以每个族都带一份 `ScanState`，在行与行之间传递。
 *
 * `#` 的语义按族分开：hash 族是行注释，css 是十六进制颜色 / ID 选择器，
 * markup 是文本。绝不能统一当注释。
 *
 * 未识别语言 → `supports()` 返回 false，调用方直接画纯文本，**不猜语言**。
 */

/** token 的语义样式。渲染侧只认这 11 种，多余的样式没有颜色可用。 */
export enum CodeTokenStyle {
  Plain = 0,
  Keyword = 1,
  Str = 2,
  Num = 3,
  Comment = 4,
  Func = 5,
  Type = 6,
  Punct = 7,
  Tag = 8,
  Attr = 9,
  Meta = 10
}

/** 一个着色片段。`text` 是原文的**连续切片**，不是加工过的文本。 */
export interface CodeToken {
  text: string;
  style: CodeTokenStyle;
}

/** 语言族（内部用，不导出：调用方只认 `supports()` / `tokenizeLines()`）。 */
enum Family {
  None = 0,
  CLike = 1,
  Hash = 2,
  Markup = 3,
  Css = 4,
  Sql = 5,
  Data = 6,
  Diff = 7
}

// ---------------------------------------------------------------------------
// 语言名 → 族的查找表
// ---------------------------------------------------------------------------

const LANG_CLIKE: string[] = [
  'js', 'javascript', 'mjs', 'cjs', 'jsx',
  'ts', 'typescript', 'tsx',
  'java', 'c', 'h', 'cpp', 'c++', 'cc', 'cxx', 'hpp', 'hh', 'hxx',
  'cs', 'csharp', 'go', 'golang', 'rust', 'rs',
  'kotlin', 'kt', 'kts', 'swift', 'php', 'scala', 'dart',
  'objective-c', 'objc', 'm', 'mm', 'scss', 'less', 'groovy'
];

const LANG_HASH: string[] = [
  'py', 'python', 'rb', 'ruby',
  'sh', 'bash', 'zsh', 'shell', 'fish',
  'yaml', 'yml', 'toml', 'ini', 'conf', 'cfg',
  'dockerfile', 'makefile', 'mk', 'r', 'perl', 'pl',
  'ps1', 'powershell', 'nginx', 'apache', 'cmake', 'gitignore'
];

const LANG_MARKUP: string[] = ['html', 'htm', 'xhtml', 'xml', 'svg', 'vue', 'svelte', 'hbs', 'handlebars', 'xaml'];

const LANG_CSS: string[] = ['css'];

const LANG_SQL: string[] = ['sql', 'mysql', 'postgresql', 'postgres', 'pgsql', 'sqlite', 'plsql'];

const LANG_DATA: string[] = ['json', 'json5', 'jsonc', 'geojson', 'jsonl', 'ndjson'];

const LANG_DIFF: string[] = ['diff', 'patch'];

// ---------------------------------------------------------------------------
// 跨行状态与输出累加器
// ---------------------------------------------------------------------------

/**
 * 行与行之间要记住的东西。
 *
 * 只有三类：在块注释里、在跨行字符串里、在 markup 标签里。加上 hash 族
 * 「本行第一个 token 是不是键」用的行首位置，就这些。
 */
class ScanState {
  /** 在 C 风格块注释（cLike/css/sql/data）或 HTML 注释（markup）里 */
  blockComment: boolean = false;
  /** 在跨行字符串里。存**结束符**：`\`\`\``、`"""`、`"###`、`]]>`；空串表示不在里面 */
  longEnd: string = '';
  /** markup：上一个 `<tag` 还没闭合，本行从标签内部开始 */
  inTag: boolean = false;
}

/**
 * 追加一个 token，并**合并**相邻同色片段。
 *
 * 合并纯粹是为了少造 `Span`：一段 2000 行、每行 8 个同色片段的代码块，
 * 不合并就是一万六千个 Span。合并只改分组，不改字符序列，所以不变式仍然成立。
 */
function pushToken(out: CodeToken[], text: string, style: CodeTokenStyle): void {
  if (text.length === 0) {
    return;
  }
  const n: number = out.length;
  if (n > 0) {
    const last: CodeToken = out[n - 1];
    if (last.style === style) {
      last.text = last.text + text;
      return;
    }
  }
  const tok: CodeToken = { text: text, style: style };
  out.push(tok);
}

// ---------------------------------------------------------------------------
// 主类
// ---------------------------------------------------------------------------

export class CodeHighlight {
  private static wordMap: Map<string, CodeTokenStyle> = new Map<string, CodeTokenStyle>();
  private static wordMapReady: boolean = false;
  private static sqlMap: Map<string, CodeTokenStyle> = new Map<string, CodeTokenStyle>();
  private static sqlMapReady: boolean = false;

  /** false → 调用方画纯文本，**不要**调 `tokenizeLines`。 */
  static supports(lang: string): boolean {
    return CodeHighlight.familyOf(lang) !== Family.None;
  }

  /**
   * 整段代码 → 逐行 token。
   *
   * 输出长度**恒等于**入参长度；每一行单独满足拼接不变式（见文件头）。
   */
  static tokenizeLines(lines: string[], lang: string): CodeToken[][] {
    const family: Family = CodeHighlight.familyOf(lang);
    const out: CodeToken[][] = [];
    const state: ScanState = new ScanState();

    for (let li = 0; li < lines.length; li++) {
      const line: string = lines[li];
      const toks: CodeToken[] = [];
      // 空行不产出 token，也**不打断**跨行状态：模板串里的空行仍然是字符串。
      if (line.length > 0) {
        if (family === Family.CLike) {
          CodeHighlight.scanCLike(state, line, toks);
        } else if (family === Family.Hash) {
          CodeHighlight.scanHash(state, line, toks);
        } else if (family === Family.Markup) {
          CodeHighlight.scanMarkup(state, line, toks);
        } else if (family === Family.Css) {
          CodeHighlight.scanCss(state, line, toks);
        } else if (family === Family.Sql) {
          CodeHighlight.scanSql(state, line, toks);
        } else if (family === Family.Data) {
          CodeHighlight.scanData(state, line, toks);
        } else if (family === Family.Diff) {
          CodeHighlight.scanDiff(line, toks);
        } else {
          // 未识别语言：整行一个 Plain token（调用方本不该走到这里）。
          pushToken(toks, line, CodeTokenStyle.Plain);
        }
        CodeHighlight.fixTrailing(line, toks);
      }
      out.push(toks);
    }
    return out;
  }

  // -------------------------------------------------------------------------
  // 语言名归一化
  // -------------------------------------------------------------------------

  /**
   * 语言名 → 族。
   *
   * 归一化只做三件事：去空白、转小写、砍掉围栏元数据（```js{1-3} 里的 `{1-3}`）。
   * 不做前缀猜测（`jsx` 不是 `js` 的变体而是独立条目，宁可查表）。
   */
  private static familyOf(lang: string): Family {
    let name: string = lang.trim().toLowerCase();
    if (name.length === 0) {
      return Family.None;
    }
    const brace: number = name.indexOf('{');
    if (brace >= 0) {
      name = name.substring(0, brace);
    }
    const space: number = name.indexOf(' ');
    if (space >= 0) {
      name = name.substring(0, space);
    }
    if (name.length === 0) {
      return Family.None;
    }
    if (LANG_CLIKE.indexOf(name) >= 0) {
      return Family.CLike;
    }
    if (LANG_HASH.indexOf(name) >= 0) {
      return Family.Hash;
    }
    if (LANG_MARKUP.indexOf(name) >= 0) {
      return Family.Markup;
    }
    if (LANG_CSS.indexOf(name) >= 0) {
      return Family.Css;
    }
    if (LANG_SQL.indexOf(name) >= 0) {
      return Family.Sql;
    }
    if (LANG_DATA.indexOf(name) >= 0) {
      return Family.Data;
    }
    if (LANG_DIFF.indexOf(name) >= 0) {
      return Family.Diff;
    }
    // text / txt / plain / log / output / 以及任何没见过的名字，一律不高亮。
    return Family.None;
  }

  // -------------------------------------------------------------------------
  // 字符分类。全部按 charCode 判断，不建正则、不建临时串。
  // -------------------------------------------------------------------------

  private static isSpaceCode(c: number): boolean {
    return c === 32 || c === 9 || c === 13;
  }

  private static isDigitCode(c: number): boolean {
    return c >= 48 && c <= 57;
  }

  private static isAlphaCode(c: number): boolean {
    return (c >= 65 && c <= 90) || (c >= 97 && c <= 122);
  }

  private static isIdentStartCode(c: number): boolean {
    return c === 95 || c === 36 || (c >= 65 && c <= 90) || (c >= 97 && c <= 122);
  }

  private static isIdentPartCode(c: number): boolean {
    return c === 95 || (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122);
  }

  private static isHexCode(c: number): boolean {
    return (c >= 48 && c <= 57) || (c >= 97 && c <= 102) || (c >= 65 && c <= 70);
  }

  /** markup 标签名：字母、数字、`-`、`:`（`svg:path`）、`_`、`.`（`<a.b>` 少见但存在） */
  private static isTagNameCode(c: number): boolean {
    return CodeHighlight.isIdentPartCode(c) || c === 45 || c === 58 || c === 46;
  }

  /** 数字后缀：`1f` `2u` `3L` `4n` `5m`（C#/Rust/Kotlin/JS bigint） */
  private static isNumSuffix(c: number): boolean {
    return c === 102 || c === 70 || c === 100 || c === 68 || c === 117 || c === 85
      || c === 108 || c === 76 || c === 110 || c === 78 || c === 109 || c === 77;
  }

  /**
   * 标点集合。
   *
   * 刻意排除 `#`（族语义不同）、引号（字符串要单独扫描）、`$`、`_`、反引号。
   * 连续标点会被合并成一个 token（`});` 一片），减少 Span 数量。
   */
  private static isPunctCode(c: number): boolean {
    return c === 33 || c === 37 || c === 38 || c === 40 || c === 41 || c === 42
      || c === 43 || c === 44 || c === 45 || c === 46 || c === 47 || c === 58
      || c === 59 || c === 60 || c === 61 || c === 62 || c === 63 || c === 64
      || c === 91 || c === 92 || c === 93 || c === 94 || c === 123 || c === 124
      || c === 125 || c === 126;
  }

  // -------------------------------------------------------------------------
  // 通用扫描片段
  // -------------------------------------------------------------------------

  /** 标识符游标：`start` 处是 ident-start，返回该词之后的位置。 */
  private static scanWord(line: string, start: number): number {
    const n: number = line.length;
    let j: number = start + 1;
    while (j < n && CodeHighlight.isIdentPartCode(line.charCodeAt(j))) {
      j++;
    }
    return j;
  }

  /** css 名字游标：额外允许 `-`（`font-size`、`#my-id`、`-webkit-box`）。 */
  private static scanCssName(line: string, start: number): number {
    const n: number = line.length;
    let j: number = start + 1;
    while (j < n) {
      const c: number = line.charCodeAt(j);
      if (c === 45 || CodeHighlight.isIdentPartCode(c)) {
        j++;
      } else {
        break;
      }
    }
    return j;
  }

  /**
   * 单行引号串：`start` 处是引号，返回**闭合引号之后**的位置。
   * 反斜杠转义会被跳过；没有闭合则返回行尾（**不**跨行——跨行由调用方决定）。
   */
  private static scanQuoted(line: string, start: number, quote: string): number {
    const n: number = line.length;
    let j: number = start + 1;
    while (j < n) {
      const c: string = line.charAt(j);
      if (c === '\\' && j + 1 < n) {
        j += 2;
        continue;
      }
      if (c === quote) {
        return j + 1;
      }
      j++;
    }
    return n;
  }

  /**
   * 数字游标。支持 `0x`/`0b`/`0o`、下划线分隔、小数、指数、类型后缀。
   * 返回至少 `start + 1`，保证外层循环永远推进。
   */
  private static scanNumber(line: string, start: number): number {
    const n: number = line.length;
    let j: number = start;

    if (line.charAt(j) === '0' && j + 1 < n) {
      const p: string = line.charAt(j + 1);
      if (p === 'x' || p === 'X' || p === 'b' || p === 'B' || p === 'o' || p === 'O') {
        j += 2;
        while (j < n && (CodeHighlight.isHexCode(line.charCodeAt(j)) || line.charAt(j) === '_')) {
          j++;
        }
        while (j < n && CodeHighlight.isNumSuffix(line.charCodeAt(j))) {
          j++;
        }
        return j > start ? j : start + 1;
      }
    }

    let seenDot: boolean = false;
    while (j < n) {
      const c: string = line.charAt(j);
      if (CodeHighlight.isDigitCode(line.charCodeAt(j)) || c === '_') {
        j++;
        continue;
      }
      if (c === '.' && !seenDot) {
        seenDot = true;
        j++;
        continue;
      }
      break;
    }

    if (j < n && (line.charAt(j) === 'e' || line.charAt(j) === 'E')) {
      let k: number = j + 1;
      if (k < n && (line.charAt(k) === '+' || line.charAt(k) === '-')) {
        k++;
      }
      if (k < n && CodeHighlight.isDigitCode(line.charCodeAt(k))) {
        j = k;
        while (j < n && CodeHighlight.isDigitCode(line.charCodeAt(j))) {
          j++;
        }
      }
    }

    while (j < n && CodeHighlight.isNumSuffix(line.charCodeAt(j))) {
      j++;
    }
    return j > start ? j : start + 1;
  }

  /** 本行第一个非空白字符的下标；全空白行返回行尾。 */
  private static firstNonSpace(line: string): number {
    const n: number = line.length;
    let i: number = 0;
    while (i < n && CodeHighlight.isSpaceCode(line.charCodeAt(i))) {
      i++;
    }
    return i;
  }

  /**
   * 把行尾空白拆成独立的 Plain token。
   *
   * 渲染侧一行是一个 `Text`，行尾空白如果留在**彩色** Span 里，排版可能把
   * 它当成可裁剪的尾随空白吃掉，复制时也会连着样式。拆出来既保住缩进也
   * 保住不变式（只是把最后一个 token 的尾巴切下来，字符一个不少）。
   */
  private static fixTrailing(line: string, toks: CodeToken[]): void {
    const n: number = line.length;
    if (n === 0 || toks.length === 0) {
      return;
    }
    let j: number = n;
    while (j > 0 && CodeHighlight.isSpaceCode(line.charCodeAt(j - 1))) {
      j--;
    }
    if (j === n) {
      return;
    }
    const last: CodeToken = toks[toks.length - 1];
    if (last.style === CodeTokenStyle.Plain) {
      return;
    }
    const ws: string = line.substring(j);
    // 兜底：切不动就不切。宁可行尾空白留在彩色 token 里，也不能让拼接少字符。
    if (last.text.length < ws.length || !last.text.endsWith(ws)) {
      return;
    }
    last.text = last.text.substring(0, last.text.length - ws.length);
    if (last.text.length === 0) {
      toks.pop();
    }
    pushToken(toks, ws, CodeTokenStyle.Plain);
  }

  // -------------------------------------------------------------------------
  // 关键字表
  // -------------------------------------------------------------------------

  /**
   * 关键字 / 类型词表。
   *
   * 单表、族内并集。用 `Map` 而不是 `indexOf` 扫数组：一个 2000 行的块有
   * 上万次查词，线性扫 250 个词会实实在在吃掉十几毫秒。
   * 表只在第一次用到时建，之后是纯哈希查找。
   */
  private static words(): Map<string, CodeTokenStyle> {
    if (CodeHighlight.wordMapReady) {
      return CodeHighlight.wordMap;
    }
    const m: Map<string, CodeTokenStyle> = CodeHighlight.wordMap;

    // 先放类型词，再放关键字：同名词以关键字为准（`var` 在 js 里是关键字，
    // 在 C# 里是类型；两害相权，按关键字画更像代码）。
    const types: string[] = [
      'int', 'char', 'float', 'double', 'long', 'short', 'byte', 'bool', 'boolean',
      'string', 'number', 'any', 'unknown', 'never', 'object', 'symbol', 'bigint',
      'unsigned', 'signed', 'size_t', 'ssize_t', 'uint', 'uint8_t', 'uint16_t',
      'uint32_t', 'uint64_t', 'int8_t', 'int16_t', 'int32_t', 'int64_t',
      'f32', 'f64', 'u8', 'u16', 'u32', 'u64', 'u128',
      'i8', 'i16', 'i32', 'i64', 'i128', 'usize', 'isize',
      'decimal', 'str', 'dynamic', 'auto'
    ];
    for (let i = 0; i < types.length; i++) {
      m.set(types[i], CodeTokenStyle.Type);
    }

    const keywords: string[] = [
      // js / ts
      'var', 'let', 'const', 'function', 'return', 'if', 'else', 'for', 'while',
      'do', 'break', 'continue', 'new', 'class', 'extends', 'super', 'this',
      'typeof', 'instanceof', 'in', 'of', 'import', 'from', 'export', 'default',
      'async', 'await', 'yield', 'try', 'catch', 'finally', 'throw', 'switch',
      'case', 'delete', 'void', 'static', 'get', 'set', 'null', 'undefined',
      'true', 'false', 'NaN', 'Infinity', 'interface', 'type', 'enum',
      'implements', 'namespace', 'declare', 'readonly', 'public', 'private',
      'protected', 'abstract', 'as', 'satisfies', 'keyof', 'infer', 'is',
      'override', 'require', 'module', 'exports',
      // c / c++ / c# / java
      'struct', 'union', 'typedef', 'sizeof', 'goto', 'extern', 'register',
      'volatile', 'inline', 'virtual', 'friend', 'template', 'typename',
      'using', 'operator', 'explicit', 'noexcept', 'constexpr', 'nullptr',
      'wchar_t', 'package', 'final', 'native', 'synchronized', 'throws',
      // go
      'func', 'chan', 'defer', 'go', 'range', 'fallthrough', 'select', 'map',
      'nil', 'iota',
      // rust
      'fn', 'mut', 'impl', 'trait', 'pub', 'use', 'crate', 'mod', 'match',
      'loop', 'where', 'dyn', 'ref', 'move', 'unsafe', 'self', 'Self',
      // kotlin / swift / scala / dart
      'fun', 'val', 'when', 'companion', 'data', 'sealed', 'init', 'lateinit',
      'suspend', 'guard', 'protocol', 'extension', 'inout', 'mutating',
      'convenience', 'required', 'lazy', 'weak', 'unowned', 'some', 'def',
      'with', 'implicit',
      // php / shell / python / ruby
      'echo', 'foreach', 'elseif', 'endif', 'array', 'list', 'isset', 'unset',
      'global', 'pass', 'elif', 'lambda', 'and', 'or', 'not', 'None', 'True',
      'False', 'print', 'len', 'isinstance', 'assert', 'del', 'nonlocal',
      'raise', 'fi', 'then', 'done', 'esac', 'source', 'local', 'shift',
      'exit', 'declare', 'alias', 'eval', 'exec', 'trap', 'wait', 'until',
      'unless', 'begin', 'rescue', 'ensure', 'include', 'extend', 'elsif',
      'when', 'puts', 'end'
    ];
    for (let i = 0; i < keywords.length; i++) {
      m.set(keywords[i], CodeTokenStyle.Keyword);
    }
    CodeHighlight.wordMapReady = true;
    return m;
  }

  /** SQL 关键字表。全大写存储，查表前把词 `toUpperCase()`。 */
  private static sqlWords(): Map<string, CodeTokenStyle> {
    if (CodeHighlight.sqlMapReady) {
      return CodeHighlight.sqlMap;
    }
    const m: Map<string, CodeTokenStyle> = CodeHighlight.sqlMap;
    const words: string[] = [
      'SELECT', 'FROM', 'WHERE', 'AND', 'OR', 'NOT', 'NULL', 'TRUE', 'FALSE',
      'INSERT', 'INTO', 'VALUES', 'UPDATE', 'SET', 'DELETE', 'CREATE', 'TABLE',
      'ALTER', 'DROP', 'INDEX', 'VIEW', 'TRIGGER', 'SCHEMA', 'DATABASE',
      'JOIN', 'LEFT', 'RIGHT', 'INNER', 'OUTER', 'FULL', 'CROSS', 'ON', 'USING',
      'GROUP', 'BY', 'ORDER', 'ASC', 'DESC', 'HAVING', 'LIMIT', 'OFFSET',
      'UNION', 'ALL', 'DISTINCT', 'AS', 'CASE', 'WHEN', 'THEN', 'ELSE', 'END',
      'IN', 'IS', 'LIKE', 'ILIKE', 'BETWEEN', 'EXISTS', 'PRIMARY', 'KEY',
      'FOREIGN', 'REFERENCES', 'UNIQUE', 'DEFAULT', 'CHECK', 'CONSTRAINT',
      'CASCADE', 'RESTRICT', 'BEGIN', 'COMMIT', 'ROLLBACK', 'TRANSACTION',
      'GRANT', 'REVOKE', 'WITH', 'RECURSIVE', 'EXPLAIN', 'ANALYZE', 'TRUNCATE',
      'PARTITION', 'OVER', 'RETURNING', 'IF', 'ELSEIF', 'LOOP', 'DECLARE',
      'PROCEDURE', 'FUNCTION', 'RETURNS', 'PRAGMA', 'AUTOINCREMENT',
      'INT', 'INTEGER', 'BIGINT', 'SMALLINT', 'VARCHAR', 'CHAR', 'TEXT',
      'BLOB', 'DATE', 'TIME', 'TIMESTAMP', 'DATETIME', 'BOOLEAN', 'NUMERIC',
      'DECIMAL', 'FLOAT', 'DOUBLE', 'SERIAL', 'JSON', 'JSONB', 'UUID',
      'COUNT', 'SUM', 'AVG', 'MIN', 'MAX', 'COALESCE', 'CAST', 'CONVERT',
      'NOW', 'ROW_NUMBER', 'RANK'
    ];
    for (let i = 0; i < words.length; i++) {
      m.set(words[i], CodeTokenStyle.Keyword);
    }
    CodeHighlight.sqlMapReady = true;
    return m;
  }

  // -------------------------------------------------------------------------
  // cLike 族
  // -------------------------------------------------------------------------

  /**
   * cLike：js/ts/java/c/c++/c#/go/rust/kotlin/swift/php/scala/dart/scss。
   *
   * 跨行状态：C 风格块注释、JS 模板串（反引号）、Go 原始串（反引号）、
   * Rust 原始串 `r#"…"#`。普通的 `"` / `'` 串**不**跨行——一个落单的引号
   * 若把后面整篇都染成字符串，比不高亮糟糕得多。
   */
  private static scanCLike(state: ScanState, line: string, out: CodeToken[]): void {
    const n: number = line.length;
    let i: number = 0;

    // ---- 接续上一行留下的状态 ----
    if (state.blockComment) {
      const end: number = line.indexOf('*/');
      if (end < 0) {
        pushToken(out, line, CodeTokenStyle.Comment);
        return;
      }
      pushToken(out, line.substring(0, end + 2), CodeTokenStyle.Comment);
      state.blockComment = false;
      i = end + 2;
    }
    if (state.longEnd.length > 0) {
      const term: string = state.longEnd;
      const end: number = line.indexOf(term, i);
      if (end < 0) {
        pushToken(out, line.substring(i), CodeTokenStyle.Str);
        return;
      }
      pushToken(out, line.substring(i, end + term.length), CodeTokenStyle.Str);
      state.longEnd = '';
      i = end + term.length;
    }

    const first: number = CodeHighlight.firstNonSpace(line);

    while (i < n) {
      const cc: number = line.charCodeAt(i);
      const c: string = line.charAt(i);

      // 空白：整段 Plain（缩进靠它活命）
      if (CodeHighlight.isSpaceCode(cc)) {
        let j: number = i + 1;
        while (j < n && CodeHighlight.isSpaceCode(line.charCodeAt(j))) {
          j++;
        }
        pushToken(out, line.substring(i, j), CodeTokenStyle.Plain);
        i = j;
        continue;
      }

      // 注释：`//` 到行尾，`/* */` 可能跨行
      if (c === '/' && i + 1 < n) {
        const c2: string = line.charAt(i + 1);
        if (c2 === '/') {
          pushToken(out, line.substring(i), CodeTokenStyle.Comment);
          return;
        }
        if (c2 === '*') {
          const end: number = line.indexOf('*/', i + 2);
          if (end < 0) {
            pushToken(out, line.substring(i), CodeTokenStyle.Comment);
            state.blockComment = true;
            return;
          }
          pushToken(out, line.substring(i, end + 2), CodeTokenStyle.Comment);
          i = end + 2;
          continue;
        }
      }

      // 行首 `#`：C 预处理、C# 指令、Rust 属性 → Meta
      if (c === '#' && i === first) {
        pushToken(out, line.substring(i), CodeTokenStyle.Meta);
        return;
      }

      // JS 模板串 / Go 原始串：可跨行
      if (c === '`') {
        const end: number = line.indexOf('`', i + 1);
        if (end < 0) {
          pushToken(out, line.substring(i), CodeTokenStyle.Str);
          state.longEnd = '`';
          return;
        }
        pushToken(out, line.substring(i, end + 1), CodeTokenStyle.Str);
        i = end + 1;
        continue;
      }

      // Rust 原始串 r"…" / r#"…"#：可跨行
      if (c === 'r' && i + 1 < n) {
        const c2: string = line.charAt(i + 1);
        if (c2 === '"' || c2 === '#') {
          let j: number = i + 1;
          let hashes: number = 0;
          while (j < n && line.charAt(j) === '#') {
            hashes++;
            j++;
          }
          if (j < n && line.charAt(j) === '"') {
            let term: string = '"';
            for (let t = 0; t < hashes; t++) {
              term += '#';
            }
            const end: number = line.indexOf(term, j + 1);
            if (end < 0) {
              pushToken(out, line.substring(i), CodeTokenStyle.Str);
              state.longEnd = term;
              return;
            }
            pushToken(out, line.substring(i, end + term.length), CodeTokenStyle.Str);
            i = end + term.length;
            continue;
          }
        }
      }

      // 普通字符串
      if (c === '"' || c === '\'') {
        const end: number = CodeHighlight.scanQuoted(line, i, c);
        pushToken(out, line.substring(i, end), CodeTokenStyle.Str);
        i = end;
        continue;
      }

      // 数字
      if (CodeHighlight.isDigitCode(cc)
        || (c === '.' && i + 1 < n && CodeHighlight.isDigitCode(line.charCodeAt(i + 1)))) {
        const end: number = CodeHighlight.scanNumber(line, i);
        pushToken(out, line.substring(i, end), CodeTokenStyle.Num);
        i = end;
        continue;
      }

      // 标识符 / 关键字 / 类型 / 函数名
      if (CodeHighlight.isIdentStartCode(cc)) {
        const end: number = CodeHighlight.scanWord(line, i);
        const word: string = line.substring(i, end);
        pushToken(out, word, CodeHighlight.classifyWord(word, line, end));
        i = end;
        continue;
      }

      // 标点：连续合并。遇到注释起点必须断开，否则 `;//` 会被当成一个标点，
      // 后面的注释正文就变成代码了。
      if (CodeHighlight.isPunctCode(cc)) {
        let j: number = i + 1;
        while (j < n && CodeHighlight.isPunctCode(line.charCodeAt(j))) {
          if (line.charAt(j) === '/' && j + 1 < n) {
            const c2: string = line.charAt(j + 1);
            if (c2 === '/' || c2 === '*') {
              break;
            }
          }
          j++;
        }
        pushToken(out, line.substring(i, j), CodeTokenStyle.Punct);
        i = j;
        continue;
      }

      // 兜底：任何没识别的字符原样输出，i 必须推进
      pushToken(out, c, CodeTokenStyle.Plain);
      i++;
    }
  }

  /** 一个词的样式：词表 → 后跟 `(` 的函数名 → 首字母大写的类型 → Plain。 */
  private static classifyWord(word: string, line: string, endIdx: number): CodeTokenStyle {
    const hit: CodeTokenStyle | undefined = CodeHighlight.words().get(word);
    if (hit !== undefined) {
      return hit;
    }
    const n: number = line.length;
    let k: number = endIdx;
    while (k < n && CodeHighlight.isSpaceCode(line.charCodeAt(k))) {
      k++;
    }
    if (k < n && line.charAt(k) === '(') {
      return CodeTokenStyle.Func;
    }
    const c0: number = word.charCodeAt(0);
    if (c0 >= 65 && c0 <= 90) {
      return CodeTokenStyle.Type;
    }
    return CodeTokenStyle.Plain;
  }

  // -------------------------------------------------------------------------
  // hash 族
  // -------------------------------------------------------------------------

  /**
   * hash：py/rb/sh/yaml/toml/ini/dockerfile/makefile/r/perl/ps1/nginx/cmake。
   *
   * `#` 在这里**是**行注释（css 与 markup 里不是，别抄这段）。
   * 跨行状态：Python 的 `"""` / `'''`。
   *
   * 近似：行首 `名字:` 认成键（YAML/INI/nginx 的主力写法）。`名字 = 值` 里的
   * `=` 两侧有空格时不认键——否则每个 Python 赋值语句的变量名都会被染色。
   */
  private static scanHash(state: ScanState, line: string, out: CodeToken[]): void {
    const n: number = line.length;
    let i: number = 0;

    if (state.longEnd.length > 0) {
      const term: string = state.longEnd;
      const end: number = line.indexOf(term);
      if (end < 0) {
        pushToken(out, line, CodeTokenStyle.Str);
        return;
      }
      pushToken(out, line.substring(0, end + term.length), CodeTokenStyle.Str);
      state.longEnd = '';
      i = end + term.length;
    }

    const first: number = CodeHighlight.firstNonSpace(line);

    while (i < n) {
      const cc: number = line.charCodeAt(i);
      const c: string = line.charAt(i);

      if (CodeHighlight.isSpaceCode(cc)) {
        let j: number = i + 1;
        while (j < n && CodeHighlight.isSpaceCode(line.charCodeAt(j))) {
          j++;
        }
        pushToken(out, line.substring(i, j), CodeTokenStyle.Plain);
        i = j;
        continue;
      }

      // `#` 行注释。shebang 单独认成 Meta。
      if (c === '#') {
        if (i === first && line.startsWith('#!', i)) {
          pushToken(out, line.substring(i), CodeTokenStyle.Meta);
        } else {
          pushToken(out, line.substring(i), CodeTokenStyle.Comment);
        }
        return;
      }

      // Python 三引号：跨行
      if (c === '"' || c === '\'') {
        const triple: string = c + c + c;
        if (line.startsWith(triple, i)) {
          const end: number = line.indexOf(triple, i + 3);
          if (end < 0) {
            pushToken(out, line.substring(i), CodeTokenStyle.Str);
            state.longEnd = triple;
            return;
          }
          pushToken(out, line.substring(i, end + 3), CodeTokenStyle.Str);
          i = end + 3;
          continue;
        }
        const end: number = CodeHighlight.scanQuoted(line, i, c);
        pushToken(out, line.substring(i, end), CodeTokenStyle.Str);
        i = end;
        continue;
      }

      // 反引号（shell 命令替换）当字符串染色
      if (c === '`') {
        const end: number = line.indexOf('`', i + 1);
        if (end < 0) {
          pushToken(out, line.substring(i), CodeTokenStyle.Str);
          return;
        }
        pushToken(out, line.substring(i, end + 1), CodeTokenStyle.Str);
        i = end + 1;
        continue;
      }

      if (CodeHighlight.isDigitCode(cc)) {
        const end: number = CodeHighlight.scanNumber(line, i);
        pushToken(out, line.substring(i, end), CodeTokenStyle.Num);
        i = end;
        continue;
      }

      if (CodeHighlight.isIdentStartCode(cc)) {
        const end: number = CodeHighlight.scanWord(line, i);
        const word: string = line.substring(i, end);
        let style: CodeTokenStyle = CodeHighlight.classifyWord(word, line, end);
        // 行首 `key:` → Attr（YAML/INI/nginx 的主力写法）
        if (style === CodeTokenStyle.Plain && i === first
          && end < n && line.charAt(end) === ':') {
          style = CodeTokenStyle.Attr;
        }
        pushToken(out, word, style);
        i = end;
        continue;
      }

      if (CodeHighlight.isPunctCode(cc)) {
        let j: number = i + 1;
        while (j < n && CodeHighlight.isPunctCode(line.charCodeAt(j))) {
          j++;
        }
        pushToken(out, line.substring(i, j), CodeTokenStyle.Punct);
        i = j;
        continue;
      }

      pushToken(out, c, CodeTokenStyle.Plain);
      i++;
    }
  }

  // -------------------------------------------------------------------------
  // markup 族
  // -------------------------------------------------------------------------

  /**
   * markup：html/xml/svg/vue/svelte/hbs/xaml。
   *
   * 四个层次分明：`<!-- -->` 注释、「标签名 Tag」、属性名 Attr、属性值 Str，
   * 尖括号与斜杠是 Punct，标签外的一切都是 Plain 正文。
   * 跨行状态：`<!-- … -->` 与 CDATA、以及**没闭合的标签**（多行属性写法）。
   */
  private static scanMarkup(state: ScanState, line: string, out: CodeToken[]): void {
    const n: number = line.length;
    let i: number = 0;

    if (state.blockComment) {
      const end: number = line.indexOf('-->');
      if (end < 0) {
        pushToken(out, line, CodeTokenStyle.Comment);
        return;
      }
      pushToken(out, line.substring(0, end + 3), CodeTokenStyle.Comment);
      state.blockComment = false;
      i = end + 3;
    }
    if (state.longEnd.length > 0) {
      const term: string = state.longEnd;
      const end: number = line.indexOf(term, i);
      if (end < 0) {
        pushToken(out, line.substring(i), CodeTokenStyle.Str);
        return;
      }
      pushToken(out, line.substring(i, end + term.length), CodeTokenStyle.Str);
      state.longEnd = '';
      i = end + term.length;
    }

    while (i < n) {
      // 上一行留下的未闭合标签
      if (state.inTag) {
        const next: number = CodeHighlight.scanTag(state, line, i, out);
        i = next > i ? next : i + 1;   // 双保险：无论 helper 返回什么都要推进
        continue;
      }

      const c: string = line.charAt(i);

      if (c === '<') {
        // 注释
        if (line.startsWith('<!--', i)) {
          const end: number = line.indexOf('-->', i + 4);
          if (end < 0) {
            pushToken(out, line.substring(i), CodeTokenStyle.Comment);
            state.blockComment = true;
            return;
          }
          pushToken(out, line.substring(i, end + 3), CodeTokenStyle.Comment);
          i = end + 3;
          continue;
        }
        // CDATA：内容是文本，用 Str
        if (line.startsWith('<![CDATA[', i)) {
          const end: number = line.indexOf(']]>', i + 9);
          if (end < 0) {
            pushToken(out, line.substring(i), CodeTokenStyle.Str);
            state.longEnd = ']]>';
            return;
          }
          pushToken(out, line.substring(i, end + 3), CodeTokenStyle.Str);
          i = end + 3;
          continue;
        }
        // DOCTYPE 之类：整段 Meta
        if (line.startsWith('<!', i)) {
          const end: number = line.indexOf('>', i + 2);
          if (end < 0) {
            pushToken(out, line.substring(i), CodeTokenStyle.Meta);
            return;
          }
          pushToken(out, line.substring(i, end + 1), CodeTokenStyle.Meta);
          i = end + 1;
          continue;
        }

        const closing: boolean = i + 1 < n && line.charAt(i + 1) === '/';
        const nameStart: number = closing ? i + 2 : i + 1;
        if (nameStart < n && CodeHighlight.isAlphaCode(line.charCodeAt(nameStart))) {
          pushToken(out, closing ? '</' : '<', CodeTokenStyle.Punct);
          let j: number = nameStart;
          while (j < n && CodeHighlight.isTagNameCode(line.charCodeAt(j))) {
            j++;
          }
          pushToken(out, line.substring(nameStart, j), CodeTokenStyle.Tag);
          i = j;
          state.inTag = true;
          continue;
        }

        // 落单的 `<`（`a < b` 这种）：标点，不当标签
        pushToken(out, '<', CodeTokenStyle.Punct);
        i++;
        continue;
      }

      // 实体：`&amp;` `&#123;`
      if (c === '&') {
        const semi: number = line.indexOf(';', i + 1);
        if (semi > i + 1 && semi - i <= 12) {
          pushToken(out, line.substring(i, semi + 1), CodeTokenStyle.Meta);
          i = semi + 1;
          continue;
        }
      }

      // 正文：吃到下一个 `<` 或 `&`
      let j: number = i + 1;
      while (j < n && line.charAt(j) !== '<' && line.charAt(j) !== '&') {
        j++;
      }
      pushToken(out, line.substring(i, j), CodeTokenStyle.Plain);
      i = j;
    }
  }

  /**
   * 标签内部：从 `i0` 扫到 `>`（含）。返回之后的位置。
   * 遇到行尾仍未闭合时保持 `state.inTag = true`，下一行继续。**一定推进**。
   */
  private static scanTag(state: ScanState, line: string, i0: number, out: CodeToken[]): number {
    const n: number = line.length;
    let i: number = i0;
    while (i < n) {
      const cc: number = line.charCodeAt(i);
      const c: string = line.charAt(i);

      if (CodeHighlight.isSpaceCode(cc)) {
        let j: number = i + 1;
        while (j < n && CodeHighlight.isSpaceCode(line.charCodeAt(j))) {
          j++;
        }
        pushToken(out, line.substring(i, j), CodeTokenStyle.Plain);
        i = j;
        continue;
      }
      if (c === '>') {
        pushToken(out, '>', CodeTokenStyle.Punct);
        state.inTag = false;
        return i + 1;
      }
      if (c === '/' || c === '=') {
        pushToken(out, c, CodeTokenStyle.Punct);
        i++;
        continue;
      }
      if (c === '"' || c === '\'') {
        const end: number = CodeHighlight.scanQuoted(line, i, c);
        pushToken(out, line.substring(i, end), CodeTokenStyle.Str);
        i = end;
        continue;
      }
      if (CodeHighlight.isIdentStartCode(cc) || c === '-') {
        const end: number = CodeHighlight.isIdentStartCode(cc)
          ? CodeHighlight.scanWord(line, i)
          : CodeHighlight.scanCssName(line, i);
        pushToken(out, line.substring(i, end), CodeTokenStyle.Attr);
        i = end;
        continue;
      }
      pushToken(out, c, CodeTokenStyle.Plain);
      i++;
    }
    return i;
  }

  // -------------------------------------------------------------------------
  // css 族
  // -------------------------------------------------------------------------

  /**
   * css。
   *
   * 关键点：`#fff` 是**颜色**不是注释；`#note` 是**选择器**。两者按
   * 「# 后面那串是不是合法的十六进制长度（3/4/6/8）」区分。
   * 跨行状态只有 C 风格块注释。
   */
  private static scanCss(state: ScanState, line: string, out: CodeToken[]): void {
    const n: number = line.length;
    let i: number = 0;

    if (state.blockComment) {
      const end: number = line.indexOf('*/');
      if (end < 0) {
        pushToken(out, line, CodeTokenStyle.Comment);
        return;
      }
      pushToken(out, line.substring(0, end + 2), CodeTokenStyle.Comment);
      state.blockComment = false;
      i = end + 2;
    }

    while (i < n) {
      const cc: number = line.charCodeAt(i);
      const c: string = line.charAt(i);

      if (CodeHighlight.isSpaceCode(cc)) {
        let j: number = i + 1;
        while (j < n && CodeHighlight.isSpaceCode(line.charCodeAt(j))) {
          j++;
        }
        pushToken(out, line.substring(i, j), CodeTokenStyle.Plain);
        i = j;
        continue;
      }

      if (c === '/' && i + 1 < n && line.charAt(i + 1) === '*') {
        const end: number = line.indexOf('*/', i + 2);
        if (end < 0) {
          pushToken(out, line.substring(i), CodeTokenStyle.Comment);
          state.blockComment = true;
          return;
        }
        pushToken(out, line.substring(i, end + 2), CodeTokenStyle.Comment);
        i = end + 2;
        continue;
      }

      if (c === '"' || c === '\'') {
        const end: number = CodeHighlight.scanQuoted(line, i, c);
        pushToken(out, line.substring(i, end), CodeTokenStyle.Str);
        i = end;
        continue;
      }

      // 颜色值 or ID 选择器
      if (c === '#') {
        let j: number = i + 1;
        while (j < n) {
          const cj: number = line.charCodeAt(j);
          if (CodeHighlight.isIdentPartCode(cj) || cj === 45) {
            j++;
          } else {
            break;
          }
        }
        const word: string = line.substring(i + 1, j);
        if (CodeHighlight.isHexColor(word)) {
          pushToken(out, line.substring(i, j), CodeTokenStyle.Num);
        } else if (word.length > 0) {
          pushToken(out, line.substring(i, j), CodeTokenStyle.Tag);
        } else {
          pushToken(out, '#', CodeTokenStyle.Punct);
          i++;
          continue;
        }
        i = j;
        continue;
      }

      // @media / @supports
      if (c === '@') {
        let j: number = i + 1;
        while (j < n) {
          const cj: number = line.charCodeAt(j);
          if (CodeHighlight.isIdentPartCode(cj) || cj === 45) {
            j++;
          } else {
            break;
          }
        }
        if (j === i + 1) {
          pushToken(out, '@', CodeTokenStyle.Punct);
          i++;
          continue;
        }
        pushToken(out, line.substring(i, j), CodeTokenStyle.Meta);
        i = j;
        continue;
      }

      // !important
      if (c === '!') {
        let j: number = i + 1;
        while (j < n && CodeHighlight.isAlphaCode(line.charCodeAt(j))) {
          j++;
        }
        if (j === i + 1) {
          pushToken(out, '!', CodeTokenStyle.Punct);
          i++;
          continue;
        }
        pushToken(out, line.substring(i, j), CodeTokenStyle.Keyword);
        i = j;
        continue;
      }

      // 数字 + 单位（12px / 1.5rem / 50%）
      if (CodeHighlight.isDigitCode(cc)
        || (c === '.' && i + 1 < n && CodeHighlight.isDigitCode(line.charCodeAt(i + 1)))) {
        let j: number = CodeHighlight.scanNumber(line, i);
        while (j < n && (CodeHighlight.isAlphaCode(line.charCodeAt(j)) || line.charAt(j) === '%')) {
          j++;
        }
        pushToken(out, line.substring(i, j), CodeTokenStyle.Num);
        i = j;
        continue;
      }

      // 类选择器 `.card`
      if (c === '.' && i + 1 < n
        && (CodeHighlight.isAlphaCode(line.charCodeAt(i + 1)) || line.charAt(i + 1) === '-')) {
        const j: number = CodeHighlight.scanCssName(line, i + 1);
        pushToken(out, line.substring(i, j), CodeTokenStyle.Tag);
        i = j;
        continue;
      }

      // 属性名 / 其它名字：紧跟 `:` 的是属性名
      if (CodeHighlight.isIdentStartCode(cc)
        || (c === '-' && i + 1 < n && CodeHighlight.isAlphaCode(line.charCodeAt(i + 1)))) {
        const end: number = CodeHighlight.scanCssName(line, i);
        let k: number = end;
        while (k < n && CodeHighlight.isSpaceCode(line.charCodeAt(k))) {
          k++;
        }
        const isProp: boolean = k < n && line.charAt(k) === ':';
        pushToken(out, line.substring(i, end), isProp ? CodeTokenStyle.Attr : CodeTokenStyle.Plain);
        i = end;
        continue;
      }

      if (CodeHighlight.isPunctCode(cc)) {
        let j: number = i + 1;
        while (j < n && CodeHighlight.isPunctCode(line.charCodeAt(j))) {
          if (line.charAt(j) === '/' && j + 1 < n && line.charAt(j + 1) === '*') {
            break;
          }
          j++;
        }
        pushToken(out, line.substring(i, j), CodeTokenStyle.Punct);
        i = j;
        continue;
      }

      pushToken(out, c, CodeTokenStyle.Plain);
      i++;
    }
  }

  /** `#fff` `#ffff` `#ffffff` `#ffffffff`（大小写不敏感）。 */
  private static isHexColor(word: string): boolean {
    const len: number = word.length;
    if (len !== 3 && len !== 4 && len !== 6 && len !== 8) {
      return false;
    }
    for (let i = 0; i < len; i++) {
      if (!CodeHighlight.isHexCode(word.charCodeAt(i))) {
        return false;
      }
    }
    return true;
  }

  // -------------------------------------------------------------------------
  // sql 族
  // -------------------------------------------------------------------------

  /**
   * sql：`--` 行注释、C 风格块注释、`'…'` 字符串（`''` 是转义）、
   * 双引号/反引号/方括号里的标识符算 Attr，关键字大小写不敏感。
   */
  private static scanSql(state: ScanState, line: string, out: CodeToken[]): void {
    const n: number = line.length;
    let i: number = 0;

    if (state.blockComment) {
      const end: number = line.indexOf('*/');
      if (end < 0) {
        pushToken(out, line, CodeTokenStyle.Comment);
        return;
      }
      pushToken(out, line.substring(0, end + 2), CodeTokenStyle.Comment);
      state.blockComment = false;
      i = end + 2;
    }

    while (i < n) {
      const cc: number = line.charCodeAt(i);
      const c: string = line.charAt(i);

      if (CodeHighlight.isSpaceCode(cc)) {
        let j: number = i + 1;
        while (j < n && CodeHighlight.isSpaceCode(line.charCodeAt(j))) {
          j++;
        }
        pushToken(out, line.substring(i, j), CodeTokenStyle.Plain);
        i = j;
        continue;
      }

      if (c === '-' && i + 1 < n && line.charAt(i + 1) === '-') {
        pushToken(out, line.substring(i), CodeTokenStyle.Comment);
        return;
      }
      if (c === '/' && i + 1 < n && line.charAt(i + 1) === '*') {
        const end: number = line.indexOf('*/', i + 2);
        if (end < 0) {
          pushToken(out, line.substring(i), CodeTokenStyle.Comment);
          state.blockComment = true;
          return;
        }
        pushToken(out, line.substring(i, end + 2), CodeTokenStyle.Comment);
        i = end + 2;
        continue;
      }

      // '…' 字符串：'' 表示一个单引号
      if (c === '\'') {
        let j: number = i + 1;
        let closed: boolean = false;
        while (j < n) {
          if (line.charAt(j) === '\'') {
            if (j + 1 < n && line.charAt(j + 1) === '\'') {
              j += 2;
              continue;
            }
            j++;
            closed = true;
            break;
          }
          j++;
        }
        if (!closed) {
          j = n;
        }
        pushToken(out, line.substring(i, j), CodeTokenStyle.Str);
        i = j;
        continue;
      }

      // 引号标识符
      if (c === '"' || c === '`' || c === '[') {
        const close: string = c === '[' ? ']' : c;
        const end: number = line.indexOf(close, i + 1);
        if (end < 0) {
          pushToken(out, line.substring(i), CodeTokenStyle.Attr);
          return;
        }
        pushToken(out, line.substring(i, end + 1), CodeTokenStyle.Attr);
        i = end + 1;
        continue;
      }

      if (CodeHighlight.isDigitCode(cc)
        || (c === '.' && i + 1 < n && CodeHighlight.isDigitCode(line.charCodeAt(i + 1)))) {
        const end: number = CodeHighlight.scanNumber(line, i);
        pushToken(out, line.substring(i, end), CodeTokenStyle.Num);
        i = end;
        continue;
      }

      if (CodeHighlight.isIdentStartCode(cc)) {
        const end: number = CodeHighlight.scanWord(line, i);
        const word: string = line.substring(i, end);
        const hit: CodeTokenStyle | undefined = CodeHighlight.sqlWords().get(word.toUpperCase());
        pushToken(out, word, hit !== undefined ? hit : CodeTokenStyle.Plain);
        i = end;
        continue;
      }

      if (CodeHighlight.isPunctCode(cc)) {
        let j: number = i + 1;
        while (j < n && CodeHighlight.isPunctCode(line.charCodeAt(j))) {
          if (line.charAt(j) === '/' && j + 1 < n && line.charAt(j + 1) === '*') {
            break;
          }
          if (line.charAt(j) === '-' && j + 1 < n && line.charAt(j + 1) === '-') {
            break;
          }
          j++;
        }
        pushToken(out, line.substring(i, j), CodeTokenStyle.Punct);
        i = j;
        continue;
      }

      pushToken(out, c, CodeTokenStyle.Plain);
      i++;
    }
  }

  // -------------------------------------------------------------------------
  // data 族（json / json5 / jsonc / geojson）
  // -------------------------------------------------------------------------

  /**
   * data：键 Attr、字符串值 Str、数字 Num、`true/false/null` Keyword。
   * 键的判定不看位置，看**这个字符串后面第一个非空白字符是不是 `:`**——
   * 数组里的字符串自然就不是键。
   */
  private static scanData(state: ScanState, line: string, out: CodeToken[]): void {
    const n: number = line.length;
    let i: number = 0;

    if (state.blockComment) {
      const end: number = line.indexOf('*/');
      if (end < 0) {
        pushToken(out, line, CodeTokenStyle.Comment);
        return;
      }
      pushToken(out, line.substring(0, end + 2), CodeTokenStyle.Comment);
      state.blockComment = false;
      i = end + 2;
    }

    while (i < n) {
      const cc: number = line.charCodeAt(i);
      const c: string = line.charAt(i);

      if (CodeHighlight.isSpaceCode(cc)) {
        let j: number = i + 1;
        while (j < n && CodeHighlight.isSpaceCode(line.charCodeAt(j))) {
          j++;
        }
        pushToken(out, line.substring(i, j), CodeTokenStyle.Plain);
        i = j;
        continue;
      }

      if (c === '/' && i + 1 < n) {
        const c2: string = line.charAt(i + 1);
        if (c2 === '/') {
          pushToken(out, line.substring(i), CodeTokenStyle.Comment);
          return;
        }
        if (c2 === '*') {
          const end: number = line.indexOf('*/', i + 2);
          if (end < 0) {
            pushToken(out, line.substring(i), CodeTokenStyle.Comment);
            state.blockComment = true;
            return;
          }
          pushToken(out, line.substring(i, end + 2), CodeTokenStyle.Comment);
          i = end + 2;
          continue;
        }
      }

      if (c === '"' || c === '\'') {
        const end: number = CodeHighlight.scanQuoted(line, i, c);
        let k: number = end;
        while (k < n && CodeHighlight.isSpaceCode(line.charCodeAt(k))) {
          k++;
        }
        const isKey: boolean = k < n && line.charAt(k) === ':';
        pushToken(out, line.substring(i, end), isKey ? CodeTokenStyle.Attr : CodeTokenStyle.Str);
        i = end;
        continue;
      }

      if (CodeHighlight.isDigitCode(cc)
        || (c === '-' && i + 1 < n && CodeHighlight.isDigitCode(line.charCodeAt(i + 1)))) {
        const end: number = CodeHighlight.scanNumber(line, i);
        pushToken(out, line.substring(i, end), CodeTokenStyle.Num);
        i = end;
        continue;
      }

      if (CodeHighlight.isIdentStartCode(cc)) {
        const end: number = CodeHighlight.scanWord(line, i);
        const word: string = line.substring(i, end);
        const isLit: boolean = word === 'true' || word === 'false' || word === 'null'
          || word === 'True' || word === 'False' || word === 'Null';
        pushToken(out, word, isLit ? CodeTokenStyle.Keyword : CodeTokenStyle.Plain);
        i = end;
        continue;
      }

      if (CodeHighlight.isPunctCode(cc)) {
        let j: number = i + 1;
        while (j < n && CodeHighlight.isPunctCode(line.charCodeAt(j))) {
          if (line.charAt(j) === '/' && j + 1 < n) {
            const c2: string = line.charAt(j + 1);
            if (c2 === '/' || c2 === '*') {
              break;
            }
          }
          j++;
        }
        pushToken(out, line.substring(i, j), CodeTokenStyle.Punct);
        i = j;
        continue;
      }

      pushToken(out, c, CodeTokenStyle.Plain);
      i++;
    }
  }

  // -------------------------------------------------------------------------
  // diff 族
  // -------------------------------------------------------------------------

  /**
   * diff：整行判定，不逐字符扫。
   * `+` 行 Str、`-` 行 Comment、`@@`/`+++`/`---` 头部 Meta、其余 Plain。
   * 注意 `---` 也以 `-` 开头，**先判头部**，顺序不能反。
   */
  private static scanDiff(line: string, out: CodeToken[]): void {
    if (line.length === 0) {
      return;
    }
    if (line.startsWith('+++') || line.startsWith('---') || line.startsWith('@@')
      || line.startsWith('diff ') || line.startsWith('index ')
      || line.startsWith('Index:') || line.startsWith('new file')
      || line.startsWith('deleted file') || line.startsWith('old mode')
      || line.startsWith('new mode') || line.startsWith('similarity index')
      || line.startsWith('rename ')) {
      pushToken(out, line, CodeTokenStyle.Meta);
      return;
    }
    const c: string = line.charAt(0);
    if (c === '+') {
      pushToken(out, line, CodeTokenStyle.Str);
      return;
    }
    if (c === '-') {
      pushToken(out, line, CodeTokenStyle.Comment);
      return;
    }
    if (c === '\\') {
      // `\ No newline at end of file`
      pushToken(out, line, CodeTokenStyle.Meta);
      return;
    }
    pushToken(out, line, CodeTokenStyle.Plain);
  }
}
