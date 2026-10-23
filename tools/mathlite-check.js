#!/usr/bin/env node
/**
 * mathlite-check.js — MathLite 的「类型剥离镜像」与断言集
 * =====================================================
 *
 * 本文件是 `entry/src/main/ets/markdown/MathLite.ets` 的**逐函数镜像**（去掉
 * ArkTS 类型标注），用来在 Node 里跑断言。它和原文件不是"两份实现"，而是同一套
 * 算法的可执行副本：改 .ets 就要同步改这里，否则这里通过的断言不再证明任何东西。
 *
 * ## 为什么值得单独写一份
 *
 * MathLite 的失效方式有两种，都很安静：
 *
 * 1. **输出为空**——渲染层会在公式位置留一块空白，读者以为笔记里没有公式。
 * 2. **不前进的循环**——这个项目被 `\frac25` 形状的输入卡死过。卡死不是断言
 *    能发现的，必须用**硬超时**：每个对抗用例都 fork 一个子进程，3 秒不返回
 *    直接 SIGKILL。同进程里的 `Date.now()` 计时在死循环里永远不会被读到。
 *
 * 所以这里除了逐条断言，还有 `probe()`：子进程 + 硬超时。
 *
 * 跑法：`node tools/mathlite-check.js`
 */

'use strict';

const { spawnSync } = require('child_process');

// ---------------------------------------------------------------------------
// 常量
// ---------------------------------------------------------------------------

const MAX_DEPTH = 16;
const THIN = '\u2009';

// ---------------------------------------------------------------------------
// 扫描结果
// ---------------------------------------------------------------------------

class Scan {
  constructor(text, next, braced) {
    this.text = text;
    this.next = next;
    this.braced = braced === true;
  }
}

class Limits {
  constructor() {
    this.lower = '';
    this.upper = '';
    this.hasLower = false;
    this.hasUpper = false;
    this.next = 0;
  }
}

// ---------------------------------------------------------------------------
// 字符判断
// ---------------------------------------------------------------------------

function isLetter(c) {
  const code = c.charCodeAt(0);
  return (code >= 65 && code <= 90) || (code >= 97 && code <= 122);
}

function isSpace(c) {
  return c === ' ' || c === '\t' || c === '\n' || c === '\r';
}

function nameEnd(src, from) {
  let i = from;
  while (i < src.length && isLetter(src.charAt(i))) i++;
  return i;
}

// ---------------------------------------------------------------------------
// Unicode 上标 / 下标表
// ---------------------------------------------------------------------------

const SUP = new Map([
  ['0', '\u2070'], ['1', '\u00B9'], ['2', '\u00B2'], ['3', '\u00B3'], ['4', '\u2074'],
  ['5', '\u2075'], ['6', '\u2076'], ['7', '\u2077'], ['8', '\u2078'], ['9', '\u2079'],
  ['+', '\u207A'], ['-', '\u207B'], ['\u2212', '\u207B'], ['=', '\u207C'],
  ['(', '\u207D'], [')', '\u207E'],
  ['a', '\u1D43'], ['b', '\u1D47'], ['c', '\u1D9C'], ['d', '\u1D48'], ['e', '\u1D49'],
  ['f', '\u1DA0'], ['g', '\u1D4D'], ['h', '\u02B0'], ['i', '\u2071'], ['j', '\u02B2'],
  ['k', '\u1D4F'], ['l', '\u02E1'], ['m', '\u1D50'], ['n', '\u207F'], ['o', '\u1D52'],
  ['p', '\u1D56'], ['r', '\u02B3'], ['s', '\u02E2'], ['t', '\u1D57'], ['u', '\u1D58'],
  ['v', '\u1D5B'], ['w', '\u02B7'], ['x', '\u02E3'], ['y', '\u02B8'], ['z', '\u1DBB'],
  ['B', '\u1D2E'], ['D', '\u1D30'], ['E', '\u1D31'], ['G', '\u1D33'], ['H', '\u1D34'],
  ['I', '\u1D35'], ['J', '\u1D36'], ['K', '\u1D37'], ['L', '\u1D38'], ['M', '\u1D39'],
  ['N', '\u1D3A'], ['O', '\u1D3C'], ['P', '\u1D3E'], ['R', '\u1D3F'], ['T', '\u1D40'],
  ['U', '\u1D41'], ['V', '\u2C7D'], ['W', '\u1D42']
]);

const SUB = new Map([
  ['0', '\u2080'], ['1', '\u2081'], ['2', '\u2082'], ['3', '\u2083'], ['4', '\u2084'],
  ['5', '\u2085'], ['6', '\u2086'], ['7', '\u2087'], ['8', '\u2088'], ['9', '\u2089'],
  ['+', '\u208A'], ['-', '\u208B'], ['\u2212', '\u208B'], ['=', '\u208C'],
  ['(', '\u208D'], [')', '\u208E'],
  ['a', '\u2090'], ['e', '\u2091'], ['h', '\u2095'], ['i', '\u1D62'], ['j', '\u2C7C'],
  ['k', '\u2096'], ['l', '\u2097'], ['m', '\u2098'], ['n', '\u2099'], ['o', '\u2092'],
  ['p', '\u209A'], ['r', '\u1D63'], ['s', '\u209B'], ['t', '\u209C'], ['u', '\u1D64'],
  ['v', '\u1D65'], ['x', '\u2093']
]);

// ---------------------------------------------------------------------------
// 符号表（.ets 里同序同内容）
// ---------------------------------------------------------------------------

const SYMBOLS = new Map([
  // 希腊字母（小写）
  ['alpha', '\u03B1'], ['beta', '\u03B2'], ['gamma', '\u03B3'], ['delta', '\u03B4'],
  ['epsilon', '\u03F5'], ['varepsilon', '\u03B5'], ['zeta', '\u03B6'], ['eta', '\u03B7'],
  ['theta', '\u03B8'], ['vartheta', '\u03D1'], ['iota', '\u03B9'], ['kappa', '\u03BA'],
  ['varkappa', '\u03F0'], ['lambda', '\u03BB'], ['mu', '\u03BC'], ['nu', '\u03BD'],
  ['xi', '\u03BE'], ['omicron', '\u03BF'], ['pi', '\u03C0'], ['varpi', '\u03D6'],
  ['rho', '\u03C1'], ['varrho', '\u03F1'], ['sigma', '\u03C3'], ['varsigma', '\u03C2'],
  ['tau', '\u03C4'], ['upsilon', '\u03C5'], ['phi', '\u03D5'], ['varphi', '\u03C6'],
  ['chi', '\u03C7'], ['psi', '\u03C8'], ['omega', '\u03C9'],
  // 希腊字母（大写）
  ['Alpha', '\u0391'], ['Beta', '\u0392'], ['Gamma', '\u0393'], ['Delta', '\u0394'],
  ['Epsilon', '\u0395'], ['Zeta', '\u0396'], ['Eta', '\u0397'], ['Theta', '\u0398'],
  ['Iota', '\u0399'], ['Kappa', '\u039A'], ['Lambda', '\u039B'], ['Mu', '\u039C'],
  ['Nu', '\u039D'], ['Xi', '\u039E'], ['Omicron', '\u039F'], ['Pi', '\u03A0'],
  ['Rho', '\u03A1'], ['Sigma', '\u03A3'], ['Tau', '\u03A4'], ['Upsilon', '\u03A5'],
  ['Phi', '\u03A6'], ['Chi', '\u03A7'], ['Psi', '\u03A8'], ['Omega', '\u03A9'],
  // 运算 / 关系 / 逻辑
  ['times', '\u00D7'], ['cdot', '\u00B7'], ['pm', '\u00B1'], ['mp', '\u2213'],
  ['div', '\u00F7'], ['leq', '\u2264'], ['le', '\u2264'], ['geq', '\u2265'],
  ['ge', '\u2265'], ['neq', '\u2260'], ['ne', '\u2260'], ['approx', '\u2248'],
  ['equiv', '\u2261'], ['sim', '\u223C'], ['simeq', '\u2243'], ['cong', '\u2245'],
  ['propto', '\u221D'], ['infty', '\u221E'], ['partial', '\u2202'], ['nabla', '\u2207'],
  ['forall', '\u2200'], ['exists', '\u2203'], ['nexists', '\u2204'], ['in', '\u2208'],
  ['notin', '\u2209'], ['ni', '\u220B'], ['subset', '\u2282'], ['supset', '\u2283'],
  ['subseteq', '\u2286'], ['supseteq', '\u2287'], ['cup', '\u222A'], ['cap', '\u2229'],
  ['setminus', '\u2216'], ['emptyset', '\u2205'], ['varnothing', '\u2205'],
  ['neg', '\u00AC'], ['lnot', '\u00AC'], ['wedge', '\u2227'], ['land', '\u2227'],
  ['vee', '\u2228'], ['lor', '\u2228'], ['vdash', '\u22A2'], ['models', '\u22A8'],
  ['top', '\u22A4'], ['bot', '\u22A5'],
  // 箭头
  ['to', '\u2192'], ['rightarrow', '\u2192'], ['longrightarrow', '\u27F6'],
  ['leftarrow', '\u2190'], ['longleftarrow', '\u27F5'], ['Rightarrow', '\u21D2'],
  ['Leftarrow', '\u21D0'], ['leftrightarrow', '\u2194'], ['Leftrightarrow', '\u21D4'],
  ['mapsto', '\u21A6'], ['uparrow', '\u2191'], ['downarrow', '\u2193'],
  // 几何 / 定界符
  ['angle', '\u2220'], ['perp', '\u22A5'], ['parallel', '\u2225'],
  ['langle', '\u27E8'], ['rangle', '\u27E9'], ['lfloor', '\u230A'], ['rfloor', '\u230B'],
  ['lceil', '\u2308'], ['rceil', '\u2309'], ['lbrace', '{'], ['rbrace', '}'],
  ['vert', '|'], ['Vert', '\u2016'],
  // 省略号与点缀
  ['ldots', '\u2026'], ['dots', '\u2026'], ['cdots', '\u22EF'], ['vdots', '\u22EE'],
  ['ddots', '\u22F1'], ['star', '\u22C6'], ['ast', '\u2217'], ['circ', '\u2218'],
  ['bullet', '\u2022'], ['degree', '\u00B0'], ['prime', '\u2032'], ['hbar', '\u210F'],
  ['ell', '\u2113'], ['surd', '\u221A'], ['therefore', '\u2234'], ['because', '\u2235'],
  ['oplus', '\u2295'], ['ominus', '\u2296'], ['otimes', '\u2297'], ['odot', '\u2299'],
  ['dagger', '\u2020'], ['ddagger', '\u2021'], ['checkmark', '\u2713'],
  ['square', '\u25A1'], ['triangle', '\u25B3']
]);

const BIG_OPS = new Map([
  ['sum', '\u2211'], ['prod', '\u220F'], ['coprod', '\u2210'], ['int', '\u222B'],
  ['iint', '\u222C'], ['iiint', '\u222D'], ['oint', '\u222E'], ['bigcup', '\u22C3'],
  ['bigcap', '\u22C2'], ['bigvee', '\u22C1'], ['bigwedge', '\u22C0'],
  ['bigoplus', '\u2A01'], ['bigotimes', '\u2A02'], ['bigodot', '\u2A00']
]);

const FUNCS = new Map([
  ['sin', 'sin'], ['cos', 'cos'], ['tan', 'tan'], ['cot', 'cot'], ['sec', 'sec'],
  ['csc', 'csc'], ['arcsin', 'arcsin'], ['arccos', 'arccos'], ['arctan', 'arctan'],
  ['sinh', 'sinh'], ['cosh', 'cosh'], ['tanh', 'tanh'], ['log', 'log'], ['lg', 'lg'],
  ['ln', 'ln'], ['exp', 'exp'], ['lim', 'lim'], ['liminf', 'liminf'],
  ['limsup', 'limsup'], ['max', 'max'], ['min', 'min'], ['sup', 'sup'], ['inf', 'inf'],
  ['det', 'det'], ['dim', 'dim'], ['ker', 'ker'], ['deg', 'deg'], ['gcd', 'gcd'],
  ['mod', 'mod'], ['bmod', 'mod']
]);

const NO_OPS = [
  'displaystyle', 'textstyle', 'scriptstyle', 'scriptscriptstyle',
  'limits', 'nolimits', 'nonumber', 'notag'
];

const TEXT_COMMANDS = [
  'text', 'textrm', 'textnormal', 'textup', 'textit', 'textbf', 'textsf', 'texttt',
  'mbox', 'hbox', 'mathrm', 'mathbf', 'mathit', 'mathsf', 'mathtt', 'mathbb',
  'mathcal', 'mathfrak', 'mathscr', 'operatorname'
];

const ACCENT_COMMANDS = [
  'hat', 'widehat', 'bar', 'vec', 'overrightarrow', 'overleftarrow',
  'dot', 'ddot', 'tilde', 'widetilde', 'check', 'breve',
  'overline', 'underline', 'overbrace', 'underbrace'
];

const DELIM_SIZERS = [
  'big', 'Big', 'bigg', 'Bigg',
  'bigl', 'Bigl', 'biggl', 'Biggl',
  'bigr', 'Bigr', 'biggr', 'Biggr',
  'bigm', 'Bigm', 'biggm', 'Biggm'
];

// ---------------------------------------------------------------------------
// MathLite（镜像）
// ---------------------------------------------------------------------------

class MathLite {
  static linearize(latex) {
    if (latex.length === 0) return '';
    let src = latex;
    try {
      src = MathLite.stripDelimiters(latex);
      if (src.length === 0) return latex;
      const out = MathLite.tidy(MathLite.emit(src, 0));
      if (out.length > 0) return out;
    } catch (e) {
      return latex;
    }
    const raw = MathLite.tidy(latex);
    return raw.length > 0 ? raw : latex;
  }

  static stripDelimiters(latex) {
    let s = MathLite.tidy(latex);
    const n = s.length;
    if (n >= 4 && s.charAt(0) === '$' && s.charAt(1) === '$'
      && s.charAt(n - 1) === '$' && s.charAt(n - 2) === '$') {
      s = s.substring(2, n - 2);
    } else if (n >= 3 && s.charAt(0) === '$' && s.charAt(n - 1) === '$'
      && s.indexOf('$', 1) === n - 1) {
      s = s.substring(1, n - 1);
    }
    return MathLite.tidy(s);
  }

  static tidy(text) {
    let start = 0;
    let end = text.length;
    while (start < end && isSpace(text.charAt(start))) start++;
    while (end > start && isSpace(text.charAt(end - 1))) end--;
    return text.substring(start, end);
  }

  static emit(src, depth) {
    if (src.length === 0) return '';
    if (depth > MAX_DEPTH) return MathLite.plain(src);
    let out = '';
    let i = 0;
    while (i < src.length) {
      const ch = src.charAt(i);
      if (ch === '\\') {
        const s = MathLite.command(src, i, depth);
        let next = s.next;
        if (next <= i) next = i + 1;
        out += s.text;
        i = next;
      } else if (ch === '{') {
        const g = MathLite.groupBody(src, i);
        let next = g.next;
        if (next <= i) next = i + 1;
        out += MathLite.emit(g.text, depth + 1);
        i = next;
      } else if (ch === '}') {
        out += '}';
        i++;
      } else if (ch === '^') {
        const a = MathLite.arg(src, i + 1, depth);
        let next = a.next;
        if (next <= i) next = i + 1;
        out += MathLite.wrapScript(a.text, true);
        i = next;
      } else if (ch === '_') {
        const a = MathLite.arg(src, i + 1, depth);
        let next = a.next;
        if (next <= i) next = i + 1;
        out += MathLite.wrapScript(a.text, false);
        i = next;
      } else if (ch === '~') {
        out += ' ';
        i++;
      } else if (isSpace(ch)) {
        if (!MathLite.endsWithSpace(out)) out += ' ';
        i++;
      } else {
        out += ch;
        i++;
      }
    }
    return out;
  }

  static endsWithSpace(text) {
    if (text.length === 0) return false;
    return text.charAt(text.length - 1) === ' ';
  }

  static groupBody(src, start) {
    let level = 0;
    let i = start;
    while (i < src.length) {
      const c = src.charAt(i);
      if (c === '\\') {
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
    return new Scan(src.substring(start + 1), src.length);
  }

  static rawArg(src, from) {
    let i = from;
    while (i < src.length && isSpace(src.charAt(i))) i++;
    if (i >= src.length) return new Scan('', i);
    const c = src.charAt(i);
    if (c === '{') {
      const g = MathLite.groupBody(src, i);
      let next = g.next;
      if (next <= i) next = i + 1;
      return new Scan(g.text, next);
    }
    if (c === '^' || c === '_' || c === '}' || c === '&') {
      return new Scan('', i);
    }
    if (c === '\\') {
      const k = isLetter(src.charAt(i + 1)) ? nameEnd(src, i + 1) : i + 2;
      const next = k > i ? k : i + 1;
      return new Scan(src.substring(i, next), next);
    }
    return new Scan(c, i + 1);
  }

  static arg(src, from, depth) {
    let i = from;
    while (i < src.length && isSpace(src.charAt(i))) i++;
    if (i >= src.length) return new Scan('', i);
    const c = src.charAt(i);
    if (c === '{') {
      const g = MathLite.groupBody(src, i);
      let next = g.next;
      if (next <= i) next = i + 1;
      return new Scan(MathLite.emit(g.text, depth + 1), next, true);
    }
    if (c === '^' || c === '_' || c === '}' || c === '&' || c === '~') {
      return new Scan('', i);
    }
    if (c === '\\') {
      const stop = MathLite.commandEnd(src, i);
      const next = stop > i ? stop : i + 1;
      return new Scan(MathLite.emit(src.substring(i, next), depth + 1), next);
    }
    return new Scan(c, i + 1);
  }

  static commandEnd(src, i) {
    let k = isLetter(src.charAt(i + 1)) ? nameEnd(src, i + 1) : i + 2;
    if (k <= i) k = i + 1;
    while (k < src.length && src.charAt(k) === '{') {
      const g = MathLite.groupBody(src, k);
      if (g.next <= k) break;
      k = g.next;
    }
    return k;
  }

  static command(src, start, depth) {
    if (start + 1 >= src.length) {
      return new Scan('\\', start + 1);
    }
    const first = src.charAt(start + 1);
    const word = isLetter(first);
    const after = word ? nameEnd(src, start + 1) : start + 2;
    const name = src.substring(start + 1, after);

    if (!word) {
      const esc = MathLite.escapeText(name);
      if (esc !== null) return new Scan(esc, after);
      return new Scan(name, after);
    }

    if (name === 'frac' || name === 'dfrac' || name === 'tfrac' || name === 'cfrac') {
      const a = MathLite.arg(src, after, depth);
      let n1 = a.next;
      if (n1 <= start) n1 = start + 1;
      const b = MathLite.arg(src, n1, depth);
      let n2 = b.next;
      if (n2 <= n1) n2 = n1 + 1;
      if (a.text.length === 0 && b.text.length === 0) return new Scan('', n2);
      return new Scan(MathLite.wrapNum(a) + '/' + MathLite.wrapNum(b), n2);
    }

    if (name === 'sqrt') {
      let k = after;
      let index = '';
      let p = k;
      while (p < src.length && isSpace(src.charAt(p))) p++;
      if (p < src.length && src.charAt(p) === '[') {
        const close = src.indexOf(']', p + 1);
        const stop = close >= 0 ? close : src.length;
        index = MathLite.tidy(MathLite.emit(src.substring(p + 1, stop), depth + 1));
        k = close >= 0 ? close + 1 : src.length;
      }
      const a = MathLite.arg(src, k, depth);
      let next = a.next;
      if (next <= start) next = start + 1;
      let head = '';
      if (index.length > 0) {
        const sup = MathLite.toSup(index);
        head = sup.length > 0 ? sup : '^(' + index + ')';
      }
      const body = a.text.length === 0 ? '' : '(' + a.text + ')';
      return new Scan(head + '\u221A' + body, next);
    }

    if (TEXT_COMMANDS.indexOf(name) >= 0) {
      const g = MathLite.rawArg(src, after);
      let next = g.next;
      if (next <= start) next = start + 1;
      return new Scan(MathLite.plain(g.text), next);
    }

    if (ACCENT_COMMANDS.indexOf(name) >= 0) {
      const a = MathLite.arg(src, after, depth);
      let next = a.next;
      if (next <= start) next = start + 1;
      return new Scan(a.text, next);
    }

    if (name === 'left' || name === 'right' || name === 'middle'
      || DELIM_SIZERS.indexOf(name) >= 0) {
      return MathLite.delimiter(src, after, depth);
    }

    if (name === 'begin') {
      const envScan = MathLite.rawArg(src, after);
      const env = MathLite.tidy(envScan.text);
      let bodyStart = envScan.next;
      if (env === 'array') {
        const spec = MathLite.rawArg(src, bodyStart);
        if (spec.text.length > 0) bodyStart = spec.next;
      }
      const endIdx = MathLite.findEnd(src, bodyStart, env);
      let body = '';
      let next = src.length;
      if (endIdx < 0) {
        body = src.substring(bodyStart);
      } else {
        body = src.substring(bodyStart, endIdx);
        const tail = MathLite.rawArg(src, endIdx + 4);
        next = tail.next > endIdx ? tail.next : endIdx + 4;
      }
      const inner = MathLite.matrixBody(body, depth, MathLite.envCellSep(env));
      const pair = MathLite.envWrap(env);
      return new Scan(pair[0] + inner + pair[1], next);
    }

    if (name === 'end') {
      const g = MathLite.rawArg(src, after);
      let next = g.next;
      if (next <= start) next = start + 1;
      return new Scan('', next);
    }

    const big = BIG_OPS.get(name);
    if (big !== undefined) {
      const lim = MathLite.readLimits(src, after, depth);
      let next = lim.next;
      if (next <= start) next = start + 1;
      return new Scan(MathLite.formatLimits(big, lim), next);
    }

    const fn = FUNCS.get(name);
    if (fn !== undefined) {
      const lim = MathLite.readLimits(src, after, depth);
      let next = lim.next;
      if (next <= start) next = start + 1;
      return new Scan(MathLite.formatLimits(fn, lim), next);
    }

    const sym = SYMBOLS.get(name);
    if (sym !== undefined) return new Scan(sym, after);

    if (name === 'quad' || name === 'qquad') return new Scan('  ', after);

    if (NO_OPS.indexOf(name) >= 0) return new Scan('', after);

    return new Scan(name, after);
  }

  static escapeText(name) {
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
      case '\\': return ' ; ';
      case ',':
      case ';':
      case ':':
      case ' ':
        return THIN;
      case '!':
        return '';
      default:
        return null;
    }
  }

  static delimiter(src, from, depth) {
    let i = from;
    while (i < src.length && isSpace(src.charAt(i))) i++;
    if (i >= src.length) return new Scan('', i);
    const c = src.charAt(i);
    if (c === '.') return new Scan('', i + 1);
    if (c === '\\') {
      const s = MathLite.command(src, i, depth);
      let next = s.next;
      if (next <= i) next = i + 1;
      return new Scan(s.text, next);
    }
    return new Scan(c, i + 1);
  }

  static wrapScript(text, sup) {
    if (text.length === 0) return '';
    const uni = sup ? MathLite.toSup(text) : MathLite.toSub(text);
    if (uni.length > 0) return uni;
    if (text.length === 1) return (sup ? '^' : '_') + text;
    return (sup ? '^(' : '_(') + text + ')';
  }

  static toSup(text) {
    if (text.length === 0) return '';
    let out = '';
    let i = 0;
    while (i < text.length) {
      const mapped = SUP.get(text.charAt(i));
      if (mapped === undefined) return '';
      out += mapped;
      i++;
    }
    return out;
  }

  static toSub(text) {
    if (text.length === 0) return '';
    let out = '';
    let i = 0;
    while (i < text.length) {
      const mapped = SUB.get(text.charAt(i));
      if (mapped === undefined) return '';
      out += mapped;
      i++;
    }
    return out;
  }

  static readLimits(src, from, depth) {
    const lim = new Limits();
    let i = from;
    while (i < src.length) {
      let k = i;
      while (k < src.length && isSpace(src.charAt(k))) k++;
      const c = k < src.length ? src.charAt(k) : '';
      if (c === '_' && !lim.hasLower) {
        const a = MathLite.arg(src, k + 1, depth);
        let next = a.next;
        if (next <= i) next = i + 1;
        lim.lower = a.text;
        lim.hasLower = true;
        i = next;
      } else if (c === '^' && !lim.hasUpper) {
        const a = MathLite.arg(src, k + 1, depth);
        let next = a.next;
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

  static formatLimits(op, lim) {
    if (!lim.hasLower && !lim.hasUpper) return op;
    const lo = lim.hasLower ? MathLite.toSub(lim.lower) : '';
    const hi = lim.hasUpper ? MathLite.toSup(lim.upper) : '';
    if (lim.hasLower && lim.hasUpper) {
      if (lo.length > 0 && hi.length > 0) return op + lo + hi;
      return op + '(' + lim.lower + '..' + lim.upper + ')';
    }
    if (lim.hasLower) {
      return op + (lo.length > 0 ? lo : '_(' + lim.lower + ')');
    }
    return op + (hi.length > 0 ? hi : '^(' + lim.upper + ')');
  }

  static findEnd(src, from, env) {
    let nest = 0;
    let i = from;
    while (i < src.length) {
      if (src.charAt(i) === '\\' && src.startsWith('\\begin', i)) {
        const e = MathLite.rawArg(src, i + 6);
        if (MathLite.tidy(e.text) === env) nest++;
        let next = e.next;
        if (next <= i) next = i + 1;
        i = next;
        continue;
      }
      if (src.charAt(i) === '\\' && src.startsWith('\\end', i)) {
        const e = MathLite.rawArg(src, i + 4);
        let next = e.next;
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

  static envWrap(env) {
    if (env === 'matrix' || env === 'smallmatrix' || env === 'array' || env === 'bmatrix') {
      return ['[', ']'];
    }
    if (env === 'pmatrix') return ['(', ')'];
    if (env === 'Bmatrix') return ['{', '}'];
    if (env === 'vmatrix') return ['|', '|'];
    if (env === 'Vmatrix') return ['\u2016', '\u2016'];
    if (env === 'cases' || env === 'dcases' || env === 'rcases') return ['{', '}'];
    return ['', ''];
  }

  static envCellSep(env) {
    if (env === 'aligned' || env === 'align' || env === 'align*' || env === 'alignedat'
      || env === 'gathered' || env === 'gather' || env === 'gather*'
      || env === 'split' || env === 'eqnarray' || env === 'eqnarray*'
      || env === 'flalign' || env === 'multline') {
      return ' ';
    }
    return ' , ';
  }

  static matrixBody(body, depth, cellSep) {
    const rows = MathLite.splitTop(body, true);
    const rowTexts = [];
    let r = 0;
    while (r < rows.length) {
      const cells = MathLite.splitTop(rows[r], false);
      const cellTexts = [];
      let c = 0;
      while (c < cells.length) {
        const text = MathLite.tidy(MathLite.emit(cells[c], depth + 1));
        if (text.length > 0) cellTexts.push(text);
        c++;
      }
      if (cellTexts.length > 0) rowTexts.push(cellTexts.join(cellSep));
      r++;
    }
    return rowTexts.join(' ; ');
  }

  static splitTop(body, rows) {
    const parts = [];
    let cur = '';
    let depth = 0;
    let i = 0;
    while (i < body.length) {
      const c = body.charAt(i);
      if (c === '\\') {
        const isBreak = i + 1 < body.length && body.charAt(i + 1) === '\\';
        if (rows && isBreak && depth === 0) {
          parts.push(cur);
          cur = '';
          i += 2;
          if (i < body.length && body.charAt(i) === '[') {
            const close = body.indexOf(']', i);
            if (close > i) i = close + 1;
          }
          continue;
        }
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

  static wrapNum(arg) {
    const text = arg.text;
    if (text.length === 0) return '';
    if (!arg.braced) return text;
    if (MathLite.fullyWrapped(text)) return text;
    return '(' + text + ')';
  }

  static fullyWrapped(text) {
    if (text.length < 2) return false;
    if (text.charAt(0) !== '(') return false;
    if (text.charAt(text.length - 1) !== ')') return false;
    let level = 0;
    let i = 0;
    while (i < text.length) {
      const c = text.charAt(i);
      if (c === '(') {
        level++;
      } else if (c === ')') {
        level--;
        if (level === 0 && i < text.length - 1) return false;
      }
      i++;
    }
    return level === 0;
  }

  static plain(src) {
    let out = '';
    let i = 0;
    while (i < src.length) {
      const c = src.charAt(i);
      if (c === '\\') {
        if (i + 1 >= src.length) {
          out += '\\';
          i++;
          continue;
        }
        if (isLetter(src.charAt(i + 1))) {
          const end = nameEnd(src, i + 1);
          const name = src.substring(i + 1, end);
          const sym = SYMBOLS.get(name);
          out += sym !== undefined ? sym : name;
          i = end;
          continue;
        }
        const name = src.charAt(i + 1);
        if (name === '\\') {
          out += ' ';
          i += 2;
          continue;
        }
        const esc = MathLite.escapeText(name);
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

// ---------------------------------------------------------------------------
// 观感检查（`node tools/mathlite-check.js --demo`）：打印真实公式的兜底文本
// ---------------------------------------------------------------------------

const DEMO = [
  '\\sum_{i=1}^{n} i^2 = \\frac{n(n+1)(2n+1)}{6}',
  '\\int_a^b f(x)\\,dx',
  '\\nabla\\cdot\\vec{E} = \\frac{\\rho}{\\varepsilon_0}',
  'e^{i\\pi}+1=0',
  '\\sqrt[3]{x^2+y^2}',
  '\\begin{vmatrix} a & b \\\\ c & d \\end{vmatrix}',
  '\\left[\\frac{\\partial^2 u}{\\partial x^2}\\right]',
  'x_{i,j} \\le \\sqrt{\\sum_{k} a_{ik}^2}',
  '\\lim_{h \\to 0}\\frac{f(x+h)-f(x)}{h}',
  '\\text{if } x \\ge 0',
  '\\overline{AB}=\\overline{A}+\\overline{B}',
  '\\begin{cases} x & x>0 \\\\ 0 & x=0 \\end{cases}',
  '\\text{速度 } v = \\frac{\\Delta s}{\\Delta t}'
];

if (process.argv[2] === '--demo') {
  for (const input of DEMO) {
    console.log(input);
    console.log('  -> ' + MathLite.linearize(input));
  }
  process.exit(0);
}

// ---------------------------------------------------------------------------
// 断言框架
// ---------------------------------------------------------------------------

let passed = 0;
const failures = [];

function eq(input, expected) {
  const actual = MathLite.linearize(input);
  if (actual === expected) {
    passed++;
    return;
  }
  failures.push({ input, expected, actual });
}

function show(s) {
  return JSON.stringify(s).replace(/[\u2009]/g, '\\u2009');
}

// ---------------------------------------------------------------------------
// 子进程探测：真正的硬超时（同进程计时在死循环里读不到）
// ---------------------------------------------------------------------------

const PROBE_TIMEOUT_MS = 3000;

function probe(input) {
  if (process.argv[2] === '--probe') return null;
  const payload = Buffer.from(input, 'utf8').toString('base64');
  const r = spawnSync(process.execPath, [__filename, '--probe', payload], {
    timeout: PROBE_TIMEOUT_MS,
    killSignal: 'SIGKILL',
    encoding: 'utf8'
  });
  if (r.error && r.error.code === 'ETIMEDOUT') {
    return { ok: false, reason: 'TIMEOUT (循环没有前进)' };
  }
  if (r.status !== 0) {
    return { ok: false, reason: 'exit=' + r.status + ' ' + (r.stderr || '').trim().slice(0, 200) };
  }
  return { ok: true, out: r.stdout };
}

// 子进程模式：读一个输入，输出线性化结果
if (process.argv[2] === '--probe') {
  const input = Buffer.from(process.argv[3], 'base64').toString('utf8');
  process.stdout.write(MathLite.linearize(input));
  process.exit(0);
}

// ---------------------------------------------------------------------------
// 1. 分数
// ---------------------------------------------------------------------------

eq('\\frac12', '1/2');
eq('\\frac\\pi2', '\u03C0/2');
eq('\\frac{a}{b}', '(a)/(b)');
eq('\\frac{a+b}{n}', '(a+b)/(n)');
eq('\\frac{1}{2}', '(1)/(2)');
eq('\\frac{12}{3}', '(12)/(3)');
eq('\\dfrac{x+1}{2}', '(x+1)/(2)');
eq('\\tfrac{\\pi}{2}', '(\u03C0)/(2)');
eq('\\frac{\\frac{a}{b}}{c}', '((a)/(b))/(c)');
eq('\\frac{(a)}{b}', '(a)/(b)');

// ---------------------------------------------------------------------------
// 2. 根号
// ---------------------------------------------------------------------------

eq('\\sqrt{x}', '\u221A(x)');
eq('\\sqrt[3]{x}', '\u00B3\u221A(x)');
eq('\\sqrt{a+b}', '\u221A(a+b)');
eq('\\sqrt2', '\u221A(2)');

// ---------------------------------------------------------------------------
// 3. 上标 / 下标
// ---------------------------------------------------------------------------

eq('x^{2}', 'x\u00B2');
eq('x^2', 'x\u00B2');
eq('n^{-1}', 'n\u207B\u00B9');
eq('x^{ab}', 'x\u1D43\u1D47');
eq('x^{1.5}', 'x^(1.5)');
eq('x^i', 'x\u2071');
eq('a_{1}', 'a\u2081');
eq('a_{ij}', 'a\u1D62\u2C7C');
eq('a_{x,y}', 'a_(x,y)');
eq('x^{n+1}', 'x\u207F\u207A\u00B9');

// ---------------------------------------------------------------------------
// 4. 定界符
// ---------------------------------------------------------------------------

eq('\\left( x \\right)', '( x )');
eq('\\left. x \\right|', 'x |');
eq('\\left\\{a\\right.', '{a');
eq('\\bigl( x \\bigr)', '( x )');
eq('\\left(\\frac{a}{b}\\right)^2', '((a)/(b))\u00B2');

// ---------------------------------------------------------------------------
// 5. 文本家族
// ---------------------------------------------------------------------------

eq('\\text{if } x', 'if x');
eq('\\mathrm{d}x', 'dx');
eq('\\mathbf{v}', 'v');
eq('\\operatorname{argmax}', 'argmax');
eq('\\mbox{const}', 'const');
eq('\\text{a^b}', 'a^b');

// ---------------------------------------------------------------------------
// 5b. 重音 / 装饰：保留内容，丢掉装饰
// ---------------------------------------------------------------------------

eq('\\hat{x}', 'x');
eq('\\overline{AB}', 'AB');
eq('\\vec{v}', 'v');
eq('\\underbrace{x+1}_{n}', 'x+1\u2099');

// ---------------------------------------------------------------------------
// 6. 矩阵 / 环境
// ---------------------------------------------------------------------------

eq('\\begin{matrix} a & b \\\\ c & d \\end{matrix}', '[a , b ; c , d]');
eq('\\begin{pmatrix} 1 & 0 \\\\ 0 & 1 \\end{pmatrix}', '(1 , 0 ; 0 , 1)');
eq('\\begin{bmatrix} 1 & 2 \\end{bmatrix}', '[1 , 2]');
eq('\\begin{cases} x & x>0 \\\\ -x & x\\leq 0 \\end{cases}', '{x , x>0 ; -x , x\u2264 0}');
eq('\\begin{aligned} a &= b \\\\ c &= d \\end{aligned}', 'a = b ; c = d');
eq('a \\\\ b', 'a  ; b');

// ---------------------------------------------------------------------------
// 7. 大型运算符
// ---------------------------------------------------------------------------

eq('\\sum_{i=1}^{n}', '\u2211\u1D62\u208C\u2081\u207F');
eq('\\sum_{k=0}^{\\infty}', '\u2211(k=0..\u221E)');
eq('\\prod_{i=1}^{n} a_i', '\u220F\u1D62\u208C\u2081\u207F a\u1D62');
eq('\\int_0^1 f', '\u222B\u2080\u00B9 f');
eq('\\lim_{x \\to 0} f', 'lim_(x \u2192 0) f');

// ---------------------------------------------------------------------------
// 8. 符号表（每组至少一条）
// ---------------------------------------------------------------------------

// 希腊字母
eq('\\alpha\\beta\\gamma\\delta', '\u03B1\u03B2\u03B3\u03B4');
eq('\\epsilon\\varepsilon\\zeta\\eta', '\u03F5\u03B5\u03B6\u03B7');
eq('\\theta\\vartheta\\iota\\kappa', '\u03B8\u03D1\u03B9\u03BA');
eq('\\lambda\\mu\\nu\\xi', '\u03BB\u03BC\u03BD\u03BE');
eq('\\pi\\rho\\sigma\\tau', '\u03C0\u03C1\u03C3\u03C4');
eq('\\upsilon\\phi\\varphi\\chi\\psi\\omega', '\u03C5\u03D5\u03C6\u03C7\u03C8\u03C9');
eq('\\Gamma\\Delta\\Theta\\Lambda', '\u0393\u0394\u0398\u039B');
eq('\\Xi\\Pi\\Sigma\\Upsilon', '\u039E\u03A0\u03A3\u03A5');
eq('\\Phi\\Psi\\Omega', '\u03A6\u03A8\u03A9');

// 运算 / 关系
eq('a\\times b\\cdot c', 'a\u00D7 b\u00B7 c');
eq('\\pm\\mp\\div', '\u00B1\u2213\u00F7');
eq('a\\leq b\\geq c\\neq d', 'a\u2264 b\u2265 c\u2260 d');
eq('\\approx\\equiv\\sim\\propto', '\u2248\u2261\u223C\u221D');
eq('\\infty\\partial\\nabla', '\u221E\u2202\u2207');
eq('\\forall x\\exists y', '\u2200 x\u2203 y');
eq('x\\in A\\notin B', 'x\u2208 A\u2209 B');
eq('A\\subset B\\supset C', 'A\u2282 B\u2283 C');
eq('A\\subseteq B\\supseteq C', 'A\u2286 B\u2287 C');
eq('A\\cup B\\cap C', 'A\u222A B\u2229 C');
eq('\\emptyset', '\u2205');

// 箭头
eq('a\\to b\\rightarrow c', 'a\u2192 b\u2192 c');
eq('a\\leftarrow b', 'a\u2190 b');
eq('a\\Rightarrow b\\Leftarrow c', 'a\u21D2 b\u21D0 c');
eq('a\\leftrightarrow b\\mapsto c', 'a\u2194 b\u21A6 c');

// 几何 / 省略号 / 点缀
eq('\\angle A \\perp B \\parallel C', '\u2220 A \u22A5 B \u2225 C');
eq('\\ldots\\cdots\\dots', '\u2026\u22EF\u2026');
eq('\\langle x\\rangle', '\u27E8 x\u27E9');
eq('\\lfloor x\\rfloor\\lceil y\\rceil', '\u230A x\u230B\u2308 y\u2309');
eq('a\\star b\\circ c\\bullet d', 'a\u22C6 b\u2218 c\u2022 d');
eq('90\\degree', '90\u00B0');
eq('f\\prime', 'f\u2032');
eq('\\hbar\\ell', '\u210F\u2113');

// 函数名
eq('\\sin x + \\cos y', 'sin x + cos y');
eq('\\log_2 8', 'log\u2082 8');
eq('\\sin^2 x', 'sin\u00B2 x');

// ---------------------------------------------------------------------------
// 9. 转义 / 间距
// ---------------------------------------------------------------------------

eq('\\{x\\}', '{x}');
eq('a\\%b', 'a%b');
eq('a\\_b', 'a_b');
eq('a\\&b', 'a&b');
eq('a\\#b', 'a#b');
eq('a\\$b', 'a$b');
eq('a\\,b', 'a' + THIN + 'b');
eq('a\\;b\\:c', 'a' + THIN + 'b' + THIN + 'c');
eq('a\\!b', 'ab');
eq('a\\quad b', 'a  b');
eq('a~b', 'a b');
eq('a\\\\\\\\b', 'a ;  ; b');

// ---------------------------------------------------------------------------
// 10. 退化路径
// ---------------------------------------------------------------------------

eq('\\foo', 'foo');
eq('\\foo{x}', 'foox');
eq('x\\notacommand y', 'xnotacommand y');
eq('{a', 'a');              // 落单左括号：组吃到文末
eq('a}', 'a}');             // 落单右括号：字面输出
eq('\\frac{a}{b', '(a)/(b)'); // 不平衡
eq('', '');
eq('\\sqrt[3', '\u00B3\u221A');   // 未闭合根指数：指数吃到文末，参数为空
eq('\\begin{matrix} a & b', '[a , b]');
eq('\\end{matrix}', '\\end{matrix}'); // 吞成空 → 退回原文（非空不变式）
eq('\\displaystyle x', 'x');

// `\text{…}` 不参与上下标
eq('\\text{x^2}', 'x^2');

// `$$…$$` / `$…$` 包裹被剥掉
eq('$$a+b$$', 'a+b');
eq('$a+b$', 'a+b');

// ---------------------------------------------------------------------------
// 11. 空输出不变式：非空输入绝不返回空串
// ---------------------------------------------------------------------------

const NON_EMPTY_PROBES = [
  '{}', '   ', '\\', '^', '_', '\\frac{}{}', '\\displaystyle', '\\!', '\\ ',
  '\\left', '\\right.', '\\begin{}', '\\end{}', '\\sqrt', 'a', '$$', '$'
];

for (const input of NON_EMPTY_PROBES) {
  const out = MathLite.linearize(input);
  if (typeof out !== 'string' || out.length === 0) {
    failures.push({ input, expected: 'non-empty string', actual: out });
  } else {
    passed++;
  }
}

// ---------------------------------------------------------------------------
// 12. 对抗输入：子进程 + 3 s 硬超时
// ---------------------------------------------------------------------------

const ADVERSARIAL = [
  // 历史事故原形：游标越过末尾又原地不动
  '\\frac25',
  '\\frac2',
  '\\frac',
  '\\frac{}{}{}{}',
  '\\frac\\frac\\frac',
  '\\\\',
  '^',
  '_^',
  'x^^2',
  'x__2',
  '\\sqrt[',
  '\\sqrt[]{}',
  '\\left',
  '\\left\\left\\left',
  '\\right.',
  '\\begin{matrix}',
  '\\begin{matrix}a',
  '\\begin{array}{cc}',
  '\\begin',
  '\\end',
  '\\sum_',
  '\\sum_{',
  '\\sum^{}',
  '\\text{',
  '{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{',
  '}}}}}}}}}}}}}}}}',
  '\\frac{a}{\\frac{b}{\\frac{c}{\\frac{d}{e}}}}',
  '\\' + 'x'.repeat(4000),
  '\\frac'.repeat(500),
  '{'.repeat(400),
  '\\begin{matrix}' + 'a&b\\\\'.repeat(200) + '\\end{matrix}',
  'a'.repeat(20000)
];

const probeFailures = [];
for (const input of ADVERSARIAL) {
  const r = probe(input);
  if (!r.ok) {
    probeFailures.push({ input: input.slice(0, 40), reason: r.reason });
  }
}

// ---------------------------------------------------------------------------
// 12b. 随机模糊：非空输入 → 非空输出（原地不动的循环会在这里变成 shell 超时）
// ---------------------------------------------------------------------------

const FZ_ALPHA = '\\{}^_&~$[]()|+-.,;: abcxyz0123456789' +
  '\\frac\\sqrt\\left\\right\\begin\\end{matrix}\\text\\sum\\le\\pi&';

let seed = 20261023;
function rnd() {
  seed = (seed * 1103515245 + 12345) & 0x7fffffff;
  return seed / 0x7fffffff;
}

for (let n = 0; n < 5000; n++) {
  const len = Math.floor(rnd() * 41);
  let input = '';
  for (let k = 0; k < len; k++) {
    input += FZ_ALPHA.charAt(Math.floor(rnd() * FZ_ALPHA.length));
  }
  const out = MathLite.linearize(input);
  const again = MathLite.linearize(input);
  if (input.length > 0 && out.length === 0) {
    failures.push({ input, expected: 'non-empty string (fuzz)', actual: out });
    break;
  }
  if (out !== again) {
    failures.push({ input, expected: 'deterministic', actual: out + ' vs ' + again });
    break;
  }
  passed++;
}


// ---------------------------------------------------------------------------
// 13. 报告
// ---------------------------------------------------------------------------

const total = passed + failures.length;
console.log('MathLite 镜像断言');
console.log('  符号表 SYMBOLS     : ' + SYMBOLS.size + ' 条');
console.log('  大型运算符 BIG_OPS : ' + BIG_OPS.size + ' 条');
console.log('  具名函数 FUNCS     : ' + FUNCS.size + ' 条');
console.log('  上标表 SUP         : ' + SUP.size + ' 条');
console.log('  下标表 SUB         : ' + SUB.size + ' 条');
console.log('  断言               : ' + passed + '/' + total + ' 通过');
console.log('  对抗用例（3s 硬超时）: ' + (ADVERSARIAL.length - probeFailures.length)
  + '/' + ADVERSARIAL.length + ' 返回');

if (failures.length > 0) {
  console.log('\n失败：');
  for (const f of failures) {
    console.log('  in=' + show(f.input)
      + '\n    期望=' + show(f.expected)
      + '\n    实际=' + show(f.actual));
  }
}

if (probeFailures.length > 0) {
  console.log('\n对抗用例失败：');
  for (const f of probeFailures) {
    console.log('  in=' + show(f.input) + ' → ' + f.reason);
  }
}

if (failures.length > 0 || probeFailures.length > 0) {
  console.log('\nFAILED');
  process.exit(1);
}

console.log('\nOK');
