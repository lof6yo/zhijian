/**
 * 纸见 · 公式线性化兜底（MathLite）
 * =================================
 *
 * ## 这个模块为什么存在
 *
 * 公式的**真正排版**由离线 KaTeX 在 ArkWeb 里完成（`rawfile/render/katex.html`），
 * 它是异步的，首屏大概率缓存未命中。在「公式块已经上屏」与「渲染图已经存在」
 * 之间有一段空窗，那段窗口里块内必须还有**可读的东西**：本模块把 LaTeX 折成
 * **一行 Unicode 文本**，读者看到的是 `(a+b)/n`，不是空白，也不是 `\frac{a+b}{n}`。
 *
 * ## 它明确不是什么（别把它"改进"成渲染器）
 *
 * 不是排版引擎：没有二维布局、没有字体度量、没有画出来的分数线。一旦开始想
 * 「先量一下这段文字多宽再摆节点」，就已经走错设计了。分数线降级成 `/`，
 * 根号降级成 `√(…)`，括号靠字符本身，上下标靠现成的 Unicode 上/下标区。
 *
 * ## 唯一的硬安全规则：每个循环都必须让游标严格前进
 *
 * 这个项目**被这个模块卡死过**：`\frac25` 形状的输入让游标越过末尾、又原地不动，
 * 循环再也不结束，整个应用冻住。所以本文件里每个「读参数 / 读组 / 读命令」的
 * 辅助函数都返回 `Scan`（文本 + 新位置），调用方**每一次**都做
 *
 *     if (next <= i) { next = i + 1; }
 *
 * 的兜底，并就近注释原因。认不出来的字符一律**恰好消费一个字符**再继续。
 * 为了同样的理由，`linearize()` 整体包在 try/catch 里：任何意外都退回原文，
 * 绝不把异常抛给渲染层（一篇文章不能因为一条公式白屏）。
 *
 * 递归深度按花括号计算，上限 `MAX_DEPTH`；超过就退化成「只还原转义的平铺复制」。
 * 现实中的公式嵌套不会超过 3 层，这个上限只是防止病态输入把栈打爆。
 *
 * ## 与渲染层的关系
 *
 * 唯一入口是 `MathLite.linearize(latex)`。KaTeX 的图就绪之前渲染它，图就绪之后
 * 直接把图盖上去——两条路径互不依赖，这个模块失败也只影响兜底文本。
 */

/** 花括号递归上限。超过后退化为平铺复制，避免病态输入爆栈。 */
const MAX_DEPTH: number = 16;

/** 细空格（U+2009）。`\,` `\;` `\:` `\ ` 用它表达 LaTeX 的正向细间距。 */
const THIN: string = '\u2009';

// ---------------------------------------------------------------------------
// 扫描结果
// ---------------------------------------------------------------------------

/**
 * 一次「读一小段」的结果：读到的文本 + 读完之后的游标位置。
 *
 * 所有辅助函数都返回它而不是「返回字符串 + 用成员变量存位置」，因为位置必须由
 * 调用方**显式**接收并做前进校验。用成员变量存游标正是历史卡死的成因。
 */
class Scan {
  text: string;
  next: number;
  /**
   * 这段文本是否来自 `{…}` 组。
   *
   * `\frac` 的括号规则要它：`\frac12`（单 token）→ `1/2`，
   * `\frac{a}{b}`（组）→ `(a)/(b)`。只看文本长度会把两者混成一个。
   */
  braced: boolean;

  constructor(text: string, next: number, braced: boolean = false) {
    this.text = text;
    this.next = next;
    this.braced = braced;
  }
}

/** 大运算符 / 函数名的上下限。`has*` 与空文本分开：`_{}` 是"有下限但为空"。 */
class Limits {
  lower: string = '';
  upper: string = '';
  hasLower: boolean = false;
  hasUpper: boolean = false;
  next: number = 0;
}

// ---------------------------------------------------------------------------
// 字符判断
// ---------------------------------------------------------------------------

function isLetter(c: string): boolean {
  const code: number = c.charCodeAt(0);
  return (code >= 65 && code <= 90) || (code >= 97 && code <= 122);
}

function isSpace(c: string): boolean {
  return c === ' ' || c === '\t' || c === '\n' || c === '\r';
}

/** 从 `from` 开始的一段字母的结束位置（`from` 指向字母时至少前进 1）。 */
function nameEnd(src: string, from: number): number {
  let i: number = from;
  while (i < src.length && isLetter(src.charAt(i))) i++;
  return i;
}

// ---------------------------------------------------------------------------
// Unicode 上标 / 下标表
// ---------------------------------------------------------------------------

function buildSup(): Map<string, string> {
  const m: Map<string, string> = new Map<string, string>();
  m.set('0', '\u2070');
  m.set('1', '\u00B9');
  m.set('2', '\u00B2');
  m.set('3', '\u00B3');
  m.set('4', '\u2074');
  m.set('5', '\u2075');
  m.set('6', '\u2076');
  m.set('7', '\u2077');
  m.set('8', '\u2078');
  m.set('9', '\u2079');
  m.set('+', '\u207A');
  m.set('-', '\u207B');
  m.set('\u2212', '\u207B');
  m.set('=', '\u207C');
  m.set('(', '\u207D');
  m.set(')', '\u207E');
  m.set('a', '\u1D43');
  m.set('b', '\u1D47');
  m.set('c', '\u1D9C');
  m.set('d', '\u1D48');
  m.set('e', '\u1D49');
  m.set('f', '\u1DA0');
  m.set('g', '\u1D4D');
  m.set('h', '\u02B0');
  m.set('i', '\u2071');
  m.set('j', '\u02B2');
  m.set('k', '\u1D4F');
  m.set('l', '\u02E1');
  m.set('m', '\u1D50');
  m.set('n', '\u207F');
  m.set('o', '\u1D52');
  m.set('p', '\u1D56');
  m.set('r', '\u02B3');
  m.set('s', '\u02E2');
  m.set('t', '\u1D57');
  m.set('u', '\u1D58');
  m.set('v', '\u1D5B');
  m.set('w', '\u02B7');
  m.set('x', '\u02E3');
  m.set('y', '\u02B8');
  m.set('z', '\u1DBB');
  m.set('B', '\u1D2E');
  m.set('D', '\u1D30');
  m.set('E', '\u1D31');
  m.set('G', '\u1D33');
  m.set('H', '\u1D34');
  m.set('I', '\u1D35');
  m.set('J', '\u1D36');
  m.set('K', '\u1D37');
  m.set('L', '\u1D38');
  m.set('M', '\u1D39');
  m.set('N', '\u1D3A');
  m.set('O', '\u1D3C');
  m.set('P', '\u1D3E');
  m.set('R', '\u1D3F');
  m.set('T', '\u1D40');
  m.set('U', '\u1D41');
  m.set('V', '\u2C7D');
  m.set('W', '\u1D42');
  return m;
}

function buildSub(): Map<string, string> {
  const m: Map<string, string> = new Map<string, string>();
  m.set('0', '\u2080');
  m.set('1', '\u2081');
  m.set('2', '\u2082');
  m.set('3', '\u2083');
  m.set('4', '\u2084');
  m.set('5', '\u2085');
  m.set('6', '\u2086');
  m.set('7', '\u2087');
  m.set('8', '\u2088');
  m.set('9', '\u2089');
  m.set('+', '\u208A');
  m.set('-', '\u208B');
  m.set('\u2212', '\u208B');
  m.set('=', '\u208C');
  m.set('(', '\u208D');
  m.set(')', '\u208E');
  m.set('a', '\u2090');
  m.set('e', '\u2091');
  m.set('h', '\u2095');
  m.set('i', '\u1D62');
  m.set('j', '\u2C7C');
  m.set('k', '\u2096');
  m.set('l', '\u2097');
  m.set('m', '\u2098');
  m.set('n', '\u2099');
  m.set('o', '\u2092');
  m.set('p', '\u209A');
  m.set('r', '\u1D63');
  m.set('s', '\u209B');
  m.set('t', '\u209C');
  m.set('u', '\u1D64');
  m.set('v', '\u1D65');
  m.set('x', '\u2093');
  return m;
}

const SUP: Map<string, string> = buildSup();
const SUB: Map<string, string> = buildSub();

// ---------------------------------------------------------------------------
// 符号表
// ---------------------------------------------------------------------------

/**
 * 符号表：命令名（不含反斜杠）→ Unicode。
 *
 * 这里只放**单字符可表达**的东西。凡是需要参数或需要结构化的命令（`\frac`
 * `\sqrt` `\left` `\begin` `\sum` …）在上面的 `command()` 里单独处理，
 * 不要往这张表里塞。
 */
function buildSymbols(): Map<string, string> {
  const m: Map<string, string> = new Map<string, string>();

  // 希腊字母（小写）
  m.set('alpha', '\u03B1');
  m.set('beta', '\u03B2');
  m.set('gamma', '\u03B3');
  m.set('delta', '\u03B4');
  m.set('epsilon', '\u03F5');
  m.set('varepsilon', '\u03B5');
  m.set('zeta', '\u03B6');
  m.set('eta', '\u03B7');
  m.set('theta', '\u03B8');
  m.set('vartheta', '\u03D1');
  m.set('iota', '\u03B9');
  m.set('kappa', '\u03BA');
  m.set('varkappa', '\u03F0');
  m.set('lambda', '\u03BB');
  m.set('mu', '\u03BC');
  m.set('nu', '\u03BD');
  m.set('xi', '\u03BE');
  m.set('omicron', '\u03BF');
  m.set('pi', '\u03C0');
  m.set('varpi', '\u03D6');
  m.set('rho', '\u03C1');
  m.set('varrho', '\u03F1');
  m.set('sigma', '\u03C3');
  m.set('varsigma', '\u03C2');
  m.set('tau', '\u03C4');
  m.set('upsilon', '\u03C5');
  m.set('phi', '\u03D5');
  m.set('varphi', '\u03C6');
  m.set('chi', '\u03C7');
  m.set('psi', '\u03C8');
  m.set('omega', '\u03C9');

  // 希腊字母（大写）
  m.set('Alpha', '\u0391');
  m.set('Beta', '\u0392');
  m.set('Gamma', '\u0393');
  m.set('Delta', '\u0394');
  m.set('Epsilon', '\u0395');
  m.set('Zeta', '\u0396');
  m.set('Eta', '\u0397');
  m.set('Theta', '\u0398');
  m.set('Iota', '\u0399');
  m.set('Kappa', '\u039A');
  m.set('Lambda', '\u039B');
  m.set('Mu', '\u039C');
  m.set('Nu', '\u039D');
  m.set('Xi', '\u039E');
  m.set('Omicron', '\u039F');
  m.set('Pi', '\u03A0');
  m.set('Rho', '\u03A1');
  m.set('Sigma', '\u03A3');
  m.set('Tau', '\u03A4');
  m.set('Upsilon', '\u03A5');
  m.set('Phi', '\u03A6');
  m.set('Chi', '\u03A7');
  m.set('Psi', '\u03A8');
  m.set('Omega', '\u03A9');

  // 运算 / 关系 / 逻辑
  m.set('times', '\u00D7');
  m.set('cdot', '\u00B7');
  m.set('pm', '\u00B1');
  m.set('mp', '\u2213');
  m.set('div', '\u00F7');
  m.set('leq', '\u2264');
  m.set('le', '\u2264');
  m.set('geq', '\u2265');
  m.set('ge', '\u2265');
  m.set('neq', '\u2260');
  m.set('ne', '\u2260');
  m.set('approx', '\u2248');
  m.set('equiv', '\u2261');
  m.set('sim', '\u223C');
  m.set('simeq', '\u2243');
  m.set('cong', '\u2245');
  m.set('propto', '\u221D');
  m.set('infty', '\u221E');
  m.set('partial', '\u2202');
  m.set('nabla', '\u2207');
  m.set('forall', '\u2200');
  m.set('exists', '\u2203');
  m.set('nexists', '\u2204');
  m.set('in', '\u2208');
  m.set('notin', '\u2209');
  m.set('ni', '\u220B');
  m.set('subset', '\u2282');
  m.set('supset', '\u2283');
  m.set('subseteq', '\u2286');
  m.set('supseteq', '\u2287');
  m.set('cup', '\u222A');
  m.set('cap', '\u2229');
  m.set('setminus', '\u2216');
  m.set('emptyset', '\u2205');
  m.set('varnothing', '\u2205');
  m.set('neg', '\u00AC');
  m.set('lnot', '\u00AC');
  m.set('wedge', '\u2227');
  m.set('land', '\u2227');
  m.set('vee', '\u2228');
  m.set('lor', '\u2228');
  m.set('vdash', '\u22A2');
  m.set('models', '\u22A8');
  m.set('top', '\u22A4');
  m.set('bot', '\u22A5');

  // 箭头
  m.set('to', '\u2192');
  m.set('rightarrow', '\u2192');
  m.set('longrightarrow', '\u27F6');
  m.set('leftarrow', '\u2190');
  m.set('longleftarrow', '\u27F5');
  m.set('Rightarrow', '\u21D2');
  m.set('Leftarrow', '\u21D0');
  m.set('leftrightarrow', '\u2194');
  m.set('Leftrightarrow', '\u21D4');
  m.set('mapsto', '\u21A6');
  m.set('uparrow', '\u2191');
  m.set('downarrow', '\u2193');

  // 几何 / 定界符
  m.set('angle', '\u2220');
  m.set('perp', '\u22A5');
  m.set('parallel', '\u2225');
  m.set('langle', '\u27E8');
  m.set('rangle', '\u27E9');
  m.set('lfloor', '\u230A');
  m.set('rfloor', '\u230B');
  m.set('lceil', '\u2308');
  m.set('rceil', '\u2309');
  m.set('lbrace', '{');
  m.set('rbrace', '}');
  m.set('vert', '|');
  m.set('Vert', '\u2016');

  // 省略号与点缀
  m.set('ldots', '\u2026');
  m.set('dots', '\u2026');
  m.set('cdots', '\u22EF');
  m.set('vdots', '\u22EE');
  m.set('ddots', '\u22F1');
  m.set('star', '\u22C6');
  m.set('ast', '\u2217');
  m.set('circ', '\u2218');
  m.set('bullet', '\u2022');
  m.set('degree', '\u00B0');
  m.set('prime', '\u2032');
  m.set('hbar', '\u210F');
  m.set('ell', '\u2113');
  m.set('surd', '\u221A');
  m.set('therefore', '\u2234');
  m.set('because', '\u2235');
  m.set('oplus', '\u2295');
  m.set('ominus', '\u2296');
  m.set('otimes', '\u2297');
  m.set('odot', '\u2299');
  m.set('dagger', '\u2020');
  m.set('ddagger', '\u2021');
  m.set('checkmark', '\u2713');
  m.set('square', '\u25A1');
  m.set('triangle', '\u25B3');

  return m;
}

const SYMBOLS: Map<string, string> = buildSymbols();

/**
 * 大型运算符：本身是符号，**但带上下限**，走 `readLimits()` 而不是通用 `_`/`^`。
 * 通用路径会把 `\sum_{k=0}^{\infty}` 拼成 `∑_(k=0)^∞`，这里要的是 `∑(k=0..∞)`。
 */
function buildBigOps(): Map<string, string> {
  const m: Map<string, string> = new Map<string, string>();
  m.set('sum', '\u2211');
  m.set('prod', '\u220F');
  m.set('coprod', '\u2210');
  m.set('int', '\u222B');
  m.set('iint', '\u222C');
  m.set('iiint', '\u222D');
  m.set('oint', '\u222E');
  m.set('bigcup', '\u22C3');
  m.set('bigcap', '\u22C2');
  m.set('bigvee', '\u22C1');
  m.set('bigwedge', '\u22C0');
  m.set('bigoplus', '\u2A01');
  m.set('bigotimes', '\u2A02');
  m.set('bigodot', '\u2A00');
  return m;
}

const BIG_OPS: Map<string, string> = buildBigOps();

/** 具名函数：输出名字本身（`\sin` → `sin`），同样接上下限。 */
function buildFuncs(): Map<string, string> {
  const m: Map<string, string> = new Map<string, string>();
  m.set('sin', 'sin');
  m.set('cos', 'cos');
  m.set('tan', 'tan');
  m.set('cot', 'cot');
  m.set('sec', 'sec');
  m.set('csc', 'csc');
  m.set('arcsin', 'arcsin');
  m.set('arccos', 'arccos');
  m.set('arctan', 'arctan');
  m.set('sinh', 'sinh');
  m.set('cosh', 'cosh');
  m.set('tanh', 'tanh');
  m.set('log', 'log');
  m.set('lg', 'lg');
  m.set('ln', 'ln');
  m.set('exp', 'exp');
  m.set('lim', 'lim');
  m.set('liminf', 'liminf');
  m.set('limsup', 'limsup');
  m.set('max', 'max');
  m.set('min', 'min');
  m.set('sup', 'sup');
  m.set('inf', 'inf');
  m.set('det', 'det');
  m.set('dim', 'dim');
  m.set('ker', 'ker');
  m.set('deg', 'deg');
  m.set('gcd', 'gcd');
  m.set('mod', 'mod');
  m.set('bmod', 'mod');
  return m;
}

const FUNCS: Map<string, string> = buildFuncs();

/** 排版类命令：只影响 TeX 自己的盒子，线性化后什么也不留。 */
const NO_OPS: string[] = [
  'displaystyle', 'textstyle', 'scriptstyle', 'scriptscriptstyle',
  'limits', 'nolimits', 'nonumber', 'notag'
];

/** `\text` 家族：内容原样保留，**不参与上下标转换**。 */
const TEXT_COMMANDS: string[] = [
  'text', 'textrm', 'textnormal', 'textup', 'textit', 'textbf', 'textsf', 'texttt',
  'mbox', 'hbox', 'mathrm', 'mathbf', 'mathit', 'mathsf', 'mathtt', 'mathbb',
  'mathcal', 'mathfrak', 'mathscr', 'operatorname'
];

/**
 * 重音 / 装饰命令：**只保留被装饰的内容**，装饰本身丢掉。
 *
 * 一行文本里没有地方放帽子、上划线或箭头。保留内容至少可读（`\overline{AB}`
 * → `AB`）；硬塞一个组合字符（U+0302 / U+0305）则依赖字体有没有那个字形，
 * 缺字形会变成豆腐块——在没有设备验证的前提下，宁可不猜。
 */
const ACCENT_COMMANDS: string[] = [
  'hat', 'widehat', 'bar', 'vec', 'overrightarrow', 'overleftarrow',
  'dot', 'ddot', 'tilde', 'widetilde', 'check', 'breve',
  'overline', 'underline', 'overbrace', 'underbrace'
];

/** 只影响括号字号的命令：后面那个定界符按原样输出。 */
const DELIM_SIZERS: string[] = [
  'big', 'Big', 'bigg', 'Bigg',
  'bigl', 'Bigl', 'biggl', 'Biggl',
  'bigr', 'Bigr', 'biggr', 'Biggr',
  'bigm', 'Bigm', 'biggm', 'Biggm'
];

// ---------------------------------------------------------------------------
// MathLite
// ---------------------------------------------------------------------------

export class MathLite {
  /**
   * LaTeX 源码 → 一行 Unicode 近似。**绝不抛异常**；非空输入不返回空串。
   *
   * 这个函数是渲染层的唯一入口：KaTeX 图未就绪时显示它的结果。
   */
  static linearize(latex: string): string {
    if (latex.length === 0) return '';
    let src: string = latex;
    try {
      src = MathLite.stripDelimiters(latex);
      if (src.length === 0) return latex;
      const out: string = MathLite.tidy(MathLite.emit(src, 0));
      if (out.length > 0) return out;
    } catch (e) {
      // 兜底：绝不把异常抛给渲染层，退回原文（读者至少还能看到 LaTeX 源码）
      return latex;
    }
    // 输出为空（例如输入只是 `{}`）：退回原文，保证"非空输入不返回空串"
    const raw: string = MathLite.tidy(latex);
    return raw.length > 0 ? raw : latex;
  }

  /**
   * 去掉调用方可能带上的 `$…$` / `$$…$$`。
   *
   * 渲染层拿到的应该是块内源码，但"整块原文"也常被顺手传进来；
   * 与其让 `$` 出现在兜底文本里，不如在这里剥一次。
   */
  private static stripDelimiters(latex: string): string {
    let s: string = MathLite.tidy(latex);
    const n: number = s.length;
    if (n >= 4 && s.charAt(0) === '$' && s.charAt(1) === '$'
      && s.charAt(n - 1) === '$' && s.charAt(n - 2) === '$') {
      s = s.substring(2, n - 2);
    } else if (n >= 3 && s.charAt(0) === '$' && s.charAt(n - 1) === '$'
      && s.indexOf('$', 1) === n - 1) {
      s = s.substring(1, n - 1);
    }
    return MathLite.tidy(s);
  }

  /** 去掉首尾空白。**不合并内部空格**：`\quad` 的两个空格必须留住。 */
  private static tidy(text: string): string {
    let start: number = 0;
    let end: number = text.length;
    while (start < end && isSpace(text.charAt(start))) start++;
    while (end > start && isSpace(text.charAt(end - 1))) end--;
    return text.substring(start, end);
  }

  // -------------------------------------------------------------------------
  // 主扫描
  // -------------------------------------------------------------------------

  /**
   * 线性化一段源码。
   *
   * 循环的每一支都在**结构上**保证 `i` 增长：要么 `i++`，要么是一个已经
   * 校验过前进的辅助函数返回值。
   */
  private static emit(src: string, depth: number): string {
    if (src.length === 0) return '';
    // 深度兜底：只还原转义的平铺复制，不再解析结构
    if (depth > MAX_DEPTH) return MathLite.plain(src);
    let out: string = '';
    let i: number = 0;
    while (i < src.length) {
      const ch: string = src.charAt(i);
      if (ch === '\\') {
        const s: Scan = MathLite.command(src, i, depth);
        let next: number = s.next;
        // 历史事故：`\frac25` 曾让游标停在原地，整个应用冻住。这里兜住任何原地不动。
        if (next <= i) next = i + 1;
        out += s.text;
        i = next;
      } else if (ch === '{') {
        // 组：内容照常线性化，括号本身不输出（TeX 里它只是分组）
        const g: Scan = MathLite.groupBody(src, i);
        let next: number = g.next;
        // 防御：组扫描没有前进就强制前进，否则死循环
        if (next <= i) next = i + 1;
        out += MathLite.emit(g.text, depth + 1);
        i = next;
      } else if (ch === '}') {
        // 落单的右括号按字面输出
        out += '}';
        i++;
      } else if (ch === '^') {
        const a: Scan = MathLite.arg(src, i + 1, depth);
        let next: number = a.next;
        // 防御：参数没读动就强制前进
        if (next <= i) next = i + 1;
        out += MathLite.wrapScript(a.text, true);
        i = next;
      } else if (ch === '_') {
        const a: Scan = MathLite.arg(src, i + 1, depth);
        let next: number = a.next;
        // 防御：参数没读动就强制前进
        if (next <= i) next = i + 1;
        out += MathLite.wrapScript(a.text, false);
        i = next;
      } else if (ch === '~') {
        // TeX 的不换行空格：一行文本里用普通空格即可
        out += ' ';
        i++;
      } else if (isSpace(ch)) {
        // 源码里的换行/缩进压成单个空格（多行 `$$` 常见），但不打断 `\quad`
        if (!MathLite.endsWithSpace(out)) out += ' ';
        i++;
      } else {
        // 认不出来的字符：**恰好消费一个字符**再继续
        out += ch;
        i++;
      }
    }
    return out;
  }

  private static endsWithSpace(text: string): boolean {
    if (text.length === 0) return false;
    return text.charAt(text.length - 1) === ' ';
  }

  // -------------------------------------------------------------------------
  // 读取一小段
  // -------------------------------------------------------------------------

  /**
   * 读 `{…}` 组，返回组内**原文**与组后位置。
   *
   * 转义对（`\{`）整对跳过，否则 `\{` 会被当成开括号并破坏配对。
   * 没有闭合时吃到文末——不平衡输入只能降级，不能抛异常。
   */
  private static groupBody(src: string, start: number): Scan {
    let level: number = 0;
    let i: number = start;
    while (i < src.length) {
      const c: string = src.charAt(i);
      if (c === '\\') {
        // 跳过 `\{` 这类转义对（也可能是 `\\`）；下一轮从 i 之后开始，严格前进
        i += 2;
        continue;
      }
      if (c === '{') {
        level++;
      } else if (c === '}') {
        level--;
        if (level === 0) return new Scan(src.substring(start + 1, i), i + 1);
      }
      i++;
    }
    // 未闭合：把剩下的都当组内内容
    return new Scan(src.substring(start + 1), src.length);
  }

  /** 读一个「原始」参数：`{…}` 取组内原文，否则取一个 token（命令名或单字符）。 */
  private static rawArg(src: string, from: number): Scan {
    let i: number = from;
    while (i < src.length && isSpace(src.charAt(i))) i++;
    if (i >= src.length) return new Scan('', i);
    const c: string = src.charAt(i);
    if (c === '{') {
      const g: Scan = MathLite.groupBody(src, i);
      let next: number = g.next;
      // 防御：组扫描没前进就强制前进
      if (next <= i) next = i + 1;
      return new Scan(g.text, next);
    }
    if (c === '^' || c === '_' || c === '}' || c === '&') {
      // 不是合法参数：不消费，留给外层按自己的规则处理
      return new Scan('', i);
    }
    if (c === '\\') {
      const k: number = isLetter(src.charAt(i + 1)) ? nameEnd(src, i + 1) : i + 2;
      // k 至少是 i+2 或字母段结束，必然 > i；仍兜一道
      const next: number = k > i ? k : i + 1;
      return new Scan(src.substring(i, next), next);
    }
    return new Scan(c, i + 1);
  }

  /**
   * 读一个**已线性化**的参数，用于 `\frac` `\sqrt` `^` `_`。
   *
   * 规则与 TeX 一致：`{…}` 是组，否则只取一个 token。命令当 token 时把紧随其后的
   * `{…}` 组一起带上，`\frac\sqrt{2}{3}` 才不会把根号丢成 `√/3`。
   */
  private static arg(src: string, from: number, depth: number): Scan {
    let i: number = from;
    while (i < src.length && isSpace(src.charAt(i))) i++;
    if (i >= src.length) return new Scan('', i);
    const c: string = src.charAt(i);
    if (c === '{') {
      const g: Scan = MathLite.groupBody(src, i);
      let next: number = g.next;
      // 防御：组扫描没前进就强制前进
      if (next <= i) next = i + 1;
      return new Scan(MathLite.emit(g.text, depth + 1), next, true);
    }
    if (c === '^' || c === '_' || c === '}' || c === '&' || c === '~') {
      // 不是合法参数：不吞掉它，让外层继续处理（例如 `a^^2`）
      return new Scan('', i);
    }
    if (c === '\\') {
      const stop: number = MathLite.commandEnd(src, i);
      const next: number = stop > i ? stop : i + 1;
      return new Scan(MathLite.emit(src.substring(i, next), depth + 1), next);
    }
    return new Scan(c, i + 1);
  }

  /** 命令（含紧随其后的 `{…}` 组）的结束位置。至少 `i + 1`，不会原地不动。 */
  private static commandEnd(src: string, i: number): number {
    let k: number = isLetter(src.charAt(i + 1)) ? nameEnd(src, i + 1) : i + 2;
    if (k <= i) k = i + 1;
    while (k < src.length && src.charAt(k) === '{') {
      const g: Scan = MathLite.groupBody(src, k);
      if (g.next <= k) break;
      k = g.next;
    }
    return k;
  }

  // -------------------------------------------------------------------------
  // 命令分发
  // -------------------------------------------------------------------------

  /** `src.charAt(start) === '\\'`。返回该命令的线性化结果与新位置。 */
  private static command(src: string, start: number, depth: number): Scan {
    if (start + 1 >= src.length) {
      // 末尾孤零零的反斜杠：按字面输出
      return new Scan('\\', start + 1);
    }
    const first: string = src.charAt(start + 1);
    const word: boolean = isLetter(first);
    const after: number = word ? nameEnd(src, start + 1) : start + 2;
    const name: string = src.substring(start + 1, after);

    // ---- 单字符转义 / 间距 / 换行 ----
    if (!word) {
      const esc: string | null = MathLite.escapeText(name);
      if (esc !== null) return new Scan(esc, after);
      // 未知转义：保留字符本身，绝不丢弃
      return new Scan(name, after);
    }

    // ---- \frac 家族 ----
    if (name === 'frac' || name === 'dfrac' || name === 'tfrac' || name === 'cfrac') {
      const a: Scan = MathLite.arg(src, after, depth);
      let n1: number = a.next;
      // 防御：第一参数没读动就强制前进，否则第二个参数在同一位置反复读
      if (n1 <= start) n1 = start + 1;
      const b: Scan = MathLite.arg(src, n1, depth);
      let n2: number = b.next;
      // 防御：同上，`\frac25` 式输入必须在这里被终结
      if (n2 <= n1) n2 = n1 + 1;
      if (a.text.length === 0 && b.text.length === 0) return new Scan('', n2);
      return new Scan(MathLite.wrapNum(a) + '/' + MathLite.wrapNum(b), n2);
    }

    // ---- \sqrt（可带根指数）----
    if (name === 'sqrt') {
      let k: number = after;
      let index: string = '';
      let p: number = k;
      while (p < src.length && isSpace(src.charAt(p))) p++;
      if (p < src.length && src.charAt(p) === '[') {
        const close: number = src.indexOf(']', p + 1);
        const stop: number = close >= 0 ? close : src.length;
        index = MathLite.tidy(MathLite.emit(src.substring(p + 1, stop), depth + 1));
        k = close >= 0 ? close + 1 : src.length;
      }
      const a: Scan = MathLite.arg(src, k, depth);
      let next: number = a.next;
      // 防御：参数没读动就强制前进
      if (next <= start) next = start + 1;
      let head: string = '';
      if (index.length > 0) {
        const sup: string = MathLite.toSup(index);
        head = sup.length > 0 ? sup : '^(' + index + ')';
      }
      const body: string = a.text.length === 0 ? '' : '(' + a.text + ')';
      return new Scan(head + '\u221A' + body, next);
    }

    // ---- \text 家族：内容原样保留 ----
    if (TEXT_COMMANDS.indexOf(name) >= 0) {
      const g: Scan = MathLite.rawArg(src, after);
      let next: number = g.next;
      // 防御：参数没读动就强制前进
      if (next <= start) next = start + 1;
      return new Scan(MathLite.plain(g.text), next);
    }

    // ---- 重音 / 装饰：只留内容 ----
    if (ACCENT_COMMANDS.indexOf(name) >= 0) {
      const a: Scan = MathLite.arg(src, after, depth);
      let next: number = a.next;
      // 防御：参数没读动就强制前进
      if (next <= start) next = start + 1;
      return new Scan(a.text, next);
    }

    // ---- \left \right \bigl … 只输出定界符本身 ----
    if (name === 'left' || name === 'right' || name === 'middle'
      || DELIM_SIZERS.indexOf(name) >= 0) {
      return MathLite.delimiter(src, after, depth);
    }

    // ---- 环境：矩阵 / cases ----
    if (name === 'begin') {
      const envScan: Scan = MathLite.rawArg(src, after);
      const env: string = MathLite.tidy(envScan.text);
      let bodyStart: number = envScan.next;
      if (env === 'array') {
        // \begin{array}{cc} 的列格式整组丢掉
        const spec: Scan = MathLite.rawArg(src, bodyStart);
        if (spec.text.length > 0) bodyStart = spec.next;
      }
      const endIdx: number = MathLite.findEnd(src, bodyStart, env);
      let body: string = '';
      let next: number = src.length;
      if (endIdx < 0) {
        // 没有 \end：吃到文末（不平衡输入降级，不抛异常）
        body = src.substring(bodyStart);
      } else {
        body = src.substring(bodyStart, endIdx);
        const tail: Scan = MathLite.rawArg(src, endIdx + 4);
        // 防御：\end{env} 没读动就跳过后面的 {env}
        next = tail.next > endIdx ? tail.next : endIdx + 4;
      }
      const inner: string = MathLite.matrixBody(body, depth, MathLite.envCellSep(env));
      const pair: string[] = MathLite.envWrap(env);
      return new Scan(pair[0] + inner + pair[1], next);
    }

    // ---- 落单的 \end：吞掉，不留痕迹 ----
    if (name === 'end') {
      const g: Scan = MathLite.rawArg(src, after);
      let next: number = g.next;
      // 防御：没读动就强制前进
      if (next <= start) next = start + 1;
      return new Scan('', next);
    }

    // ---- 大型运算符：带上下限 ----
    const big: string | undefined = BIG_OPS.get(name);
    if (big !== undefined) {
      const lim: Limits = MathLite.readLimits(src, after, depth);
      let next: number = lim.next;
      // 防御：上下限没读动就强制前进
      if (next <= start) next = start + 1;
      return new Scan(MathLite.formatLimits(big, lim), next);
    }

    // ---- 具名函数：输出名字，同样接上下限（`\sin^2 x`）----
    const fn: string | undefined = FUNCS.get(name);
    if (fn !== undefined) {
      const lim: Limits = MathLite.readLimits(src, after, depth);
      let next: number = lim.next;
      // 防御：上下限没读动就强制前进
      if (next <= start) next = start + 1;
      return new Scan(MathLite.formatLimits(fn, lim), next);
    }

    // ---- 普通符号 ----
    const sym: string | undefined = SYMBOLS.get(name);
    if (sym !== undefined) return new Scan(sym, after);

    // ---- 间距 ----
    if (name === 'quad' || name === 'qquad') return new Scan('  ', after);

    // ---- 排版空操作 ----
    if (NO_OPS.indexOf(name) >= 0) return new Scan('', after);

    // ---- 未知命令：去掉反斜杠保留名字，**绝不丢弃** ----
    return new Scan(name, after);
  }

  /**
   * 单字符转义与间距命令 → 文本。不是转义命令返回 `null`。
   *
   * 正向细间距（`\,` `\;` `\:` `\ `）统一成一个细空格 U+2009；
   * 负向的 `\!` 不占位。这是刻意选的唯一口径，不要在别处另立一套。
   */
  private static escapeText(name: string): string | null {
    switch (name) {
      case '{': return '{';
      case '}': return '}';
      case '|': return '\u2016';
      case '%': return '%';
      case '_': return '_';
      case '&': return '&';
      case '#': return '#';
      case '$': return '$';
      case '~': return '~';
      case '\\': return ' ; '; // 换行 / 矩阵行分隔
      case ',':
      case ';':
      case ':':
      case ' ':
        return THIN;
      case '!':
        return '';             // 负向细间距：不占位
      default:
        return null;
    }
  }

  /** 定界符命令：读紧跟的定界符并原样输出。`\left.` / `\right.` 输出空。 */
  private static delimiter(src: string, from: number, depth: number): Scan {
    let i: number = from;
    while (i < src.length && isSpace(src.charAt(i))) i++;
    if (i >= src.length) return new Scan('', i);
    const c: string = src.charAt(i);
    // `\left.` / `\right.`：TeX 的"这一侧不可见"
    if (c === '.') return new Scan('', i + 1);
    if (c === '\\') {
      const s: Scan = MathLite.command(src, i, depth);
      let next: number = s.next;
      // 防御：命令没读动就只吞掉反斜杠，避免在两个命令之间打转
      if (next <= i) next = i + 1;
      return new Scan(s.text, next);
    }
    return new Scan(c, i + 1);
  }

  // -------------------------------------------------------------------------
  // 上下标
  // -------------------------------------------------------------------------

  /**
   * 上下标输出。整段都能转 Unicode 就转（`x²`、`n⁻¹`）；
   * 否则退化：单字符 `^x` / `_x`，多字符 `^(…)` / `_(…)`。
   */
  private static wrapScript(text: string, sup: boolean): string {
    if (text.length === 0) return '';
    const uni: string = sup ? MathLite.toSup(text) : MathLite.toSub(text);
    if (uni.length > 0) return uni;
    if (text.length === 1) return (sup ? '^' : '_') + text;
    return (sup ? '^(' : '_(') + text + ')';
  }

  /** 逐字符转上标；有一个转不了就返回空串表示"整体失败"。 */
  private static toSup(text: string): string {
    if (text.length === 0) return '';
    let out: string = '';
    let i: number = 0;
    while (i < text.length) {
      const mapped: string | undefined = SUP.get(text.charAt(i));
      if (mapped === undefined) return '';
      out += mapped;
      i++;
    }
    return out;
  }

  /** 逐字符转下标；有一个转不了就返回空串表示"整体失败"。 */
  private static toSub(text: string): string {
    if (text.length === 0) return '';
    let out: string = '';
    let i: number = 0;
    while (i < text.length) {
      const mapped: string | undefined = SUB.get(text.charAt(i));
      if (mapped === undefined) return '';
      out += mapped;
      i++;
    }
    return out;
  }

  // -------------------------------------------------------------------------
  // 大运算符的上下限
  // -------------------------------------------------------------------------

  /** 读紧跟运算符的 `_…` / `^…`（顺序不限，各至多一个）。 */
  private static readLimits(src: string, from: number, depth: number): Limits {
    const lim: Limits = new Limits();
    let i: number = from;
    while (i < src.length) {
      let k: number = i;
      while (k < src.length && isSpace(src.charAt(k))) k++;
      const c: string = k < src.length ? src.charAt(k) : '';
      if (c === '_' && !lim.hasLower) {
        const a: Scan = MathLite.arg(src, k + 1, depth);
        let next: number = a.next;
        // 防御：参数没读动就强制前进，否则同一个 `_` 被无限重读
        if (next <= i) next = i + 1;
        lim.lower = a.text;
        lim.hasLower = true;
        i = next;
      } else if (c === '^' && !lim.hasUpper) {
        const a: Scan = MathLite.arg(src, k + 1, depth);
        let next: number = a.next;
        // 防御：同上
        if (next <= i) next = i + 1;
        lim.upper = a.text;
        lim.hasUpper = true;
        i = next;
      } else {
        break;
      }
    }
    lim.next = i;
    return lim;
  }

  /**
   * 运算符 + 上下限的拼装。
   *
   * 两者都能转 Unicode → `∑ᵢ₌₁ⁿ`；否则退回线性写法 `∑(i=1..n)`。
   * 只有一侧时，能转就转，不能转就用 `^(…)` / `_(…)`。
   */
  private static formatLimits(op: string, lim: Limits): string {
    if (!lim.hasLower && !lim.hasUpper) return op;
    const lo: string = lim.hasLower ? MathLite.toSub(lim.lower) : '';
    const hi: string = lim.hasUpper ? MathLite.toSup(lim.upper) : '';
    if (lim.hasLower && lim.hasUpper) {
      if (lo.length > 0 && hi.length > 0) return op + lo + hi;
      return op + '(' + lim.lower + '..' + lim.upper + ')';
    }
    if (lim.hasLower) {
      return op + (lo.length > 0 ? lo : '_(' + lim.lower + ')');
    }
    return op + (hi.length > 0 ? hi : '^(' + lim.upper + ')');
  }

  // -------------------------------------------------------------------------
  // 矩阵 / 环境
  // -------------------------------------------------------------------------

  /**
   * 找匹配的 `\end{env}`，返回 `\end` 中反斜杠的下标；找不到返回 -1。
   *
   * 只为**同名**环境计数嵌套：`\begin{matrix}` 里套一个 `\begin{cases}` 时
   * 内层不该影响外层的匹配。
   */
  private static findEnd(src: string, from: number, env: string): number {
    let nest: number = 0;
    let i: number = from;
    while (i < src.length) {
      if (src.charAt(i) === '\\' && src.startsWith('\\begin', i)) {
        const e: Scan = MathLite.rawArg(src, i + 6);
        if (MathLite.tidy(e.text) === env) nest++;
        let next: number = e.next;
        // 防御：环境名没读动就强制前进，否则在同一个 \begin 上打转
        if (next <= i) next = i + 1;
        i = next;
        continue;
      }
      if (src.charAt(i) === '\\' && src.startsWith('\\end', i)) {
        const e: Scan = MathLite.rawArg(src, i + 4);
        let next: number = e.next;
        // 防御：同上
        if (next <= i) next = i + 1;
        if (MathLite.tidy(e.text) === env) {
          if (nest === 0) return i;
          nest--;
        }
        i = next;
        continue;
      }
      i++;
    }
    return -1;
  }

  /** 环境名 → 包裹符号（首尾各一个）。空串表示不包裹。 */
  private static envWrap(env: string): string[] {
    if (env === 'matrix' || env === 'smallmatrix' || env === 'array' || env === 'bmatrix') {
      return ['[', ']'];
    }
    if (env === 'pmatrix') return ['(', ')'];
    if (env === 'Bmatrix') return ['{', '}'];
    if (env === 'vmatrix') return ['|', '|'];
    if (env === 'Vmatrix') return ['\u2016', '\u2016'];
    if (env === 'cases' || env === 'dcases' || env === 'rcases') return ['{', '}'];
    // aligned / gather / split / equation 等只分行，不加括号
    return ['', ''];
  }

  /**
   * 格间分隔符。
   *
   * 矩阵 / cases 里 `&` 是**列**分隔，写成 ` , ` 可读；对齐环境里 `&` 只是
   * 对齐点（`a &= b`），写成 `a , = b` 就不可读了，改成补一个空格。
   */
  private static envCellSep(env: string): string {
    if (env === 'aligned' || env === 'align' || env === 'align*' || env === 'alignedat'
      || env === 'gathered' || env === 'gather' || env === 'gather*'
      || env === 'split' || env === 'eqnarray' || env === 'eqnarray*'
      || env === 'flalign' || env === 'multline') {
      return ' ';
    }
    return ' , ';
  }

  /** 环境体 → `行1 ; 行2`，格间用 ` , `。 */
  private static matrixBody(body: string, depth: number, cellSep: string): string {
    const rows: string[] = MathLite.splitTop(body, true);
    const rowTexts: string[] = [];
    let r: number = 0;
    while (r < rows.length) {
      const cells: string[] = MathLite.splitTop(rows[r], false);
      const cellTexts: string[] = [];
      let c: number = 0;
      while (c < cells.length) {
        const text: string = MathLite.tidy(MathLite.emit(cells[c], depth + 1));
        if (text.length > 0) cellTexts.push(text);
        c++;
      }
      if (cellTexts.length > 0) rowTexts.push(cellTexts.join(cellSep));
      r++;
    }
    return rowTexts.join(' ; ');
  }

  /**
   * 在花括号深度 0 上切分：`rows = true` 按 `\\` 切行，否则按 `&` 切格。
   *
   * `\\` 后面的可选间距 `\\[2pt]` 一并丢掉。深度由 `{`/`}` 维护，
   * `\text{a & b}` 里的 `&` 就不会被当成分格符。
   */
  private static splitTop(body: string, rows: boolean): string[] {
    const parts: string[] = [];
    let cur: string = '';
    let depth: number = 0;
    let i: number = 0;
    while (i < body.length) {
      const c: string = body.charAt(i);
      if (c === '\\') {
        const isBreak: boolean = i + 1 < body.length && body.charAt(i + 1) === '\\';
        if (rows && isBreak && depth === 0) {
          parts.push(cur);
          cur = '';
          i += 2;
          // 丢掉 \\[2pt] 这类可选间距
          if (i < body.length && body.charAt(i) === '[') {
            const close: number = body.indexOf(']', i);
            if (close > i) i = close + 1;
          }
          continue;
        }
        // 其它命令整段照抄，交给 emit 处理（游标严格前进）
        cur += c;
        i++;
        continue;
      }
      if (!rows && c === '&' && depth === 0) {
        parts.push(cur);
        cur = '';
        i++;
        continue;
      }
      if (c === '{') {
        depth++;
      } else if (c === '}') {
        if (depth > 0) depth--;
      }
      cur += c;
      i++;
    }
    parts.push(cur);
    return parts;
  }

  // -------------------------------------------------------------------------
  // 数字 / 文本小工具
  // -------------------------------------------------------------------------

  /**
   * `\frac` 的参数是否要括号。
   *
   * 规则（这是 `\frac12` 与 `\frac{a}{b}` 的分界）：
   * - 无括号单 token（`\frac12`、`\frac\pi2`）→ 不加括号；
   * - 来自 `{…}` 组（`\frac{a}{b}`、`\frac{12}{3}`）→ 加括号，
   *   因为组是作者"这就是一个整体"的显式声明；
   * - 组内已经是一对完整括号（`\frac{(a)}{b}`）→ 不叠第二层。
   */
  private static wrapNum(arg: Scan): string {
    const text: string = arg.text;
    if (text.length === 0) return '';
    if (!arg.braced) return text;
    if (MathLite.fullyWrapped(text)) return text;
    return '(' + text + ')';
  }

  /** 整串是否恰好被一对 `(` … `)` 完整包住（首括号与末括号配对）。 */
  private static fullyWrapped(text: string): boolean {
    if (text.length < 2) return false;
    if (text.charAt(0) !== '(') return false;
    if (text.charAt(text.length - 1) !== ')') return false;
    let level: number = 0;
    let i: number = 0;
    while (i < text.length) {
      const c: string = text.charAt(i);
      if (c === '(') {
        level++;
      } else if (c === ')') {
        level--;
        // 在中途就合上了，说明末尾那个 `)` 不对应首字符
        if (level === 0 && i < text.length - 1) return false;
      }
      i++;
    }
    return level === 0;
  }

  /**
   * 「平铺复制」：只还原转义与命令名，不解析结构。
   *
   * 两处用它：超过 `MAX_DEPTH` 的兜底，以及 `\text{…}` 的内容
   * （那里绝不能把 `a^2` 转成上标——TeX 的文本模式本来就没有上标）。
   */
  private static plain(src: string): string {
    let out: string = '';
    let i: number = 0;
    while (i < src.length) {
      const c: string = src.charAt(i);
      if (c === '\\') {
        if (i + 1 >= src.length) {
          out += '\\';
          i++;
          continue;
        }
        if (isLetter(src.charAt(i + 1))) {
          const end: number = nameEnd(src, i + 1);
          const name: string = src.substring(i + 1, end);
          const sym: string | undefined = SYMBOLS.get(name);
          out += sym !== undefined ? sym : name;
          i = end;
          continue;
        }
        const name: string = src.charAt(i + 1);
        if (name === '\\') {
          out += ' ';
          i += 2;
          continue;
        }
        const esc: string | null = MathLite.escapeText(name);
        out += esc !== null ? esc : name;
        i += 2;
        continue;
      }
      if (c === '~') {
        out += ' ';
        i++;
        continue;
      }
      if (isSpace(c)) {
        if (!MathLite.endsWithSpace(out)) out += ' ';
        i++;
        continue;
      }
      out += c;
      i++;
    }
    return out;
  }
}
