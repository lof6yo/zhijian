#!/usr/bin/env node
/**
 * highlight-check.js — 代码高亮分词器的「不变式」回归测试
 * =====================================================
 *
 * 这是 `entry/src/main/ets/markdown/CodeHighlight.ets` 的**无类型副本**：
 * 逐行照抄扫描逻辑（去掉 ArkTS 类型注解、把枚举换成普通数字），不做任何
 * 额外的「顺手优化」——本文件唯一的价值就是和它比对。
 *
 * ## 为什么只断言不变式
 *
 * 高亮是个主观产物：关键字少认一个、颜色深一格，都只是难看。
 * 但分词器一旦**丢字符、重复字符、错位**，代码块显示的就是另一段代码，
 * 用户复制走的是他没写过的东西——这是不可接受的静默数据损坏。
 *
 * 所以本文件断言只有一条，但对语料的**每一行**都断言：
 *
 *     tokens.map(t => t.text).join('') === 原文行
 *     tokens.length === lines.length
 *
 * 外加若干「状态必须跨行维持」的定点断言（多行注释、模板串、三引号、
 * CSS 的 `#fff` 不是注释、diff 头部），因为那类错误拼接仍然对得上，
 * 只有看样式才发现。
 *
 * ## 手工核对过的输入（写在这里备查，机器不可见的部分）
 *
 * 用模拟器上的真实文档抽样核对过渲染结果：
 *   - 一份 Kotlin 文件里跨 5 行的 KDoc 文档注释：第 2–5 行整行 Comment；
 *   - 微信小程序文档里的 HTML 片段（多行属性、`<!-- -->`、`&nbsp;`）；
 *   - 一份 `.env`/YAML 混合配置（行首 `KEY:` 认成 Attr，`#` 是注释）；
 *   - 一篇含 MathJax 公式说明的 Markdown，其中的 JS 模板串跨 4 行。
 *
 * 运行：node tools/highlight-check.js
 */

'use strict';

// ---------------------------------------------------------------------------
// 样式 / 族
// ---------------------------------------------------------------------------

const S = {
  Plain: 0, Keyword: 1, Str: 2, Num: 3, Comment: 4,
  Func: 5, Type: 6, Punct: 7, Tag: 8, Attr: 9, Meta: 10
};

const F = {
  None: 0, CLike: 1, Hash: 2, Markup: 3, Css: 4, Sql: 5, Data: 6, Diff: 7
};

const LANG_CLIKE = [
  'js', 'javascript', 'mjs', 'cjs', 'jsx',
  'ts', 'typescript', 'tsx',
  'java', 'c', 'h', 'cpp', 'c++', 'cc', 'cxx', 'hpp', 'hh', 'hxx',
  'cs', 'csharp', 'go', 'golang', 'rust', 'rs',
  'kotlin', 'kt', 'kts', 'swift', 'php', 'scala', 'dart',
  'objective-c', 'objc', 'm', 'mm', 'scss', 'less', 'groovy'
];
const LANG_HASH = [
  'py', 'python', 'rb', 'ruby',
  'sh', 'bash', 'zsh', 'shell', 'fish',
  'yaml', 'yml', 'toml', 'ini', 'conf', 'cfg',
  'dockerfile', 'makefile', 'mk', 'r', 'perl', 'pl',
  'ps1', 'powershell', 'nginx', 'apache', 'cmake', 'gitignore'
];
const LANG_MARKUP = ['html', 'htm', 'xhtml', 'xml', 'svg', 'vue', 'svelte', 'hbs', 'handlebars', 'xaml'];
const LANG_CSS = ['css'];
const LANG_SQL = ['sql', 'mysql', 'postgresql', 'postgres', 'pgsql', 'sqlite', 'plsql'];
const LANG_DATA = ['json', 'json5', 'jsonc', 'geojson', 'jsonl', 'ndjson'];
const LANG_DIFF = ['diff', 'patch'];

// ---------------------------------------------------------------------------
// 输出累加器
// ---------------------------------------------------------------------------

function pushToken(out, text, style) {
  if (text.length === 0) return;
  const n = out.length;
  if (n > 0) {
    const last = out[n - 1];
    if (last.style === style) {
      last.text = last.text + text;
      return;
    }
  }
  out.push({ text: text, style: style });
}

// ---------------------------------------------------------------------------
// 字符分类
// ---------------------------------------------------------------------------

function isSpaceCode(c) { return c === 32 || c === 9 || c === 13; }
function isDigitCode(c) { return c >= 48 && c <= 57; }
function isAlphaCode(c) { return (c >= 65 && c <= 90) || (c >= 97 && c <= 122); }
function isIdentStartCode(c) {
  return c === 95 || c === 36 || (c >= 65 && c <= 90) || (c >= 97 && c <= 122);
}
function isIdentPartCode(c) {
  return c === 95 || (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122);
}
function isHexCode(c) {
  return (c >= 48 && c <= 57) || (c >= 97 && c <= 102) || (c >= 65 && c <= 70);
}
function isTagNameCode(c) {
  return isIdentPartCode(c) || c === 45 || c === 58 || c === 46;
}
function isNumSuffix(c) {
  return c === 102 || c === 70 || c === 100 || c === 68 || c === 117 || c === 85 ||
    c === 108 || c === 76 || c === 110 || c === 78 || c === 109 || c === 77;
}
function isPunctCode(c) {
  return c === 33 || c === 37 || c === 38 || c === 40 || c === 41 || c === 42 ||
    c === 43 || c === 44 || c === 45 || c === 46 || c === 47 || c === 58 ||
    c === 59 || c === 60 || c === 61 || c === 62 || c === 63 || c === 64 ||
    c === 91 || c === 92 || c === 93 || c === 94 || c === 123 || c === 124 ||
    c === 125 || c === 126;
}

// ---------------------------------------------------------------------------
// 通用扫描片段
// ---------------------------------------------------------------------------

function scanWord(line, start) {
  const n = line.length;
  let j = start + 1;
  while (j < n && isIdentPartCode(line.charCodeAt(j))) j++;
  return j;
}

function scanCssName(line, start) {
  const n = line.length;
  let j = start + 1;
  while (j < n) {
    const c = line.charCodeAt(j);
    if (c === 45 || isIdentPartCode(c)) j++; else break;
  }
  return j;
}

function scanQuoted(line, start, quote) {
  const n = line.length;
  let j = start + 1;
  while (j < n) {
    const c = line.charAt(j);
    if (c === '\\' && j + 1 < n) { j += 2; continue; }
    if (c === quote) return j + 1;
    j++;
  }
  return n;
}

function scanNumber(line, start) {
  const n = line.length;
  let j = start;

  if (line.charAt(j) === '0' && j + 1 < n) {
    const p = line.charAt(j + 1);
    if (p === 'x' || p === 'X' || p === 'b' || p === 'B' || p === 'o' || p === 'O') {
      j += 2;
      while (j < n && (isHexCode(line.charCodeAt(j)) || line.charAt(j) === '_')) j++;
      while (j < n && isNumSuffix(line.charCodeAt(j))) j++;
      return j > start ? j : start + 1;
    }
  }

  let seenDot = false;
  while (j < n) {
    const c = line.charAt(j);
    if (isDigitCode(line.charCodeAt(j)) || c === '_') { j++; continue; }
    if (c === '.' && !seenDot) { seenDot = true; j++; continue; }
    break;
  }

  if (j < n && (line.charAt(j) === 'e' || line.charAt(j) === 'E')) {
    let k = j + 1;
    if (k < n && (line.charAt(k) === '+' || line.charAt(k) === '-')) k++;
    if (k < n && isDigitCode(line.charCodeAt(k))) {
      j = k;
      while (j < n && isDigitCode(line.charCodeAt(j))) j++;
    }
  }

  while (j < n && isNumSuffix(line.charCodeAt(j))) j++;
  return j > start ? j : start + 1;
}

function firstNonSpace(line) {
  const n = line.length;
  let i = 0;
  while (i < n && isSpaceCode(line.charCodeAt(i))) i++;
  return i;
}

function fixTrailing(line, toks) {
  const n = line.length;
  if (n === 0 || toks.length === 0) return;
  let j = n;
  while (j > 0 && isSpaceCode(line.charCodeAt(j - 1))) j--;
  if (j === n) return;
  const last = toks[toks.length - 1];
  if (last.style === S.Plain) return;
  const ws = line.substring(j);
  if (last.text.length < ws.length || !last.text.endsWith(ws)) return;
  last.text = last.text.substring(0, last.text.length - ws.length);
  if (last.text.length === 0) toks.pop();
  pushToken(toks, ws, S.Plain);
}

// ---------------------------------------------------------------------------
// 关键字表
// ---------------------------------------------------------------------------

const wordMap = new Map();

function words() {
  if (wordMap.size > 0) return wordMap;
  const types = [
    'int', 'char', 'float', 'double', 'long', 'short', 'byte', 'bool', 'boolean',
    'string', 'number', 'any', 'unknown', 'never', 'object', 'symbol', 'bigint',
    'unsigned', 'signed', 'size_t', 'ssize_t', 'uint', 'uint8_t', 'uint16_t',
    'uint32_t', 'uint64_t', 'int8_t', 'int16_t', 'int32_t', 'int64_t',
    'f32', 'f64', 'u8', 'u16', 'u32', 'u64', 'u128',
    'i8', 'i16', 'i32', 'i64', 'i128', 'usize', 'isize',
    'decimal', 'str', 'dynamic', 'auto'
  ];
  for (const t of types) wordMap.set(t, S.Type);
  const keywords = [
    'var', 'let', 'const', 'function', 'return', 'if', 'else', 'for', 'while',
    'do', 'break', 'continue', 'new', 'class', 'extends', 'super', 'this',
    'typeof', 'instanceof', 'in', 'of', 'import', 'from', 'export', 'default',
    'async', 'await', 'yield', 'try', 'catch', 'finally', 'throw', 'switch',
    'case', 'delete', 'void', 'static', 'get', 'set', 'null', 'undefined',
    'true', 'false', 'NaN', 'Infinity', 'interface', 'type', 'enum',
    'implements', 'namespace', 'declare', 'readonly', 'public', 'private',
    'protected', 'abstract', 'as', 'satisfies', 'keyof', 'infer', 'is',
    'override', 'require', 'module', 'exports',
    'struct', 'union', 'typedef', 'sizeof', 'goto', 'extern', 'register',
    'volatile', 'inline', 'virtual', 'friend', 'template', 'typename',
    'using', 'operator', 'explicit', 'noexcept', 'constexpr', 'nullptr',
    'wchar_t', 'package', 'final', 'native', 'synchronized', 'throws',
    'func', 'chan', 'defer', 'go', 'range', 'fallthrough', 'select', 'map',
    'nil', 'iota',
    'fn', 'mut', 'impl', 'trait', 'pub', 'use', 'crate', 'mod', 'match',
    'loop', 'where', 'dyn', 'ref', 'move', 'unsafe', 'self', 'Self',
    'fun', 'val', 'when', 'companion', 'data', 'sealed', 'init', 'lateinit',
    'suspend', 'guard', 'protocol', 'extension', 'inout', 'mutating',
    'convenience', 'required', 'lazy', 'weak', 'unowned', 'some', 'def',
    'with', 'implicit',
    'echo', 'foreach', 'elseif', 'endif', 'array', 'list', 'isset', 'unset',
    'global', 'pass', 'elif', 'lambda', 'and', 'or', 'not', 'None', 'True',
    'False', 'print', 'len', 'isinstance', 'assert', 'del', 'nonlocal',
    'raise', 'fi', 'then', 'done', 'esac', 'source', 'local', 'shift',
    'exit', 'declare', 'alias', 'eval', 'exec', 'trap', 'wait', 'until',
    'unless', 'begin', 'rescue', 'ensure', 'include', 'extend', 'elsif',
    'when', 'puts', 'end'
  ];
  for (const k of keywords) wordMap.set(k, S.Keyword);
  return wordMap;
}

const sqlMap = new Map();
function sqlWords() {
  if (sqlMap.size > 0) return sqlMap;
  const ws = [
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
  for (const w of ws) sqlMap.set(w, S.Keyword);
  return sqlMap;
}

function classifyWord(word, line, endIdx) {
  const hit = words().get(word);
  if (hit !== undefined) return hit;
  const n = line.length;
  let k = endIdx;
  while (k < n && isSpaceCode(line.charCodeAt(k))) k++;
  if (k < n && line.charAt(k) === '(') return S.Func;
  const c0 = word.charCodeAt(0);
  if (c0 >= 65 && c0 <= 90) return S.Type;
  return S.Plain;
}

// ---------------------------------------------------------------------------
// 扫描器（与 .ets 逐行对应）
// ---------------------------------------------------------------------------

function newState() {
  return { blockComment: false, longEnd: '', inTag: false };
}

function scanCLike(state, line, out) {
  const n = line.length;
  let i = 0;

  if (state.blockComment) {
    const end = line.indexOf('*/');
    if (end < 0) { pushToken(out, line, S.Comment); return; }
    pushToken(out, line.substring(0, end + 2), S.Comment);
    state.blockComment = false;
    i = end + 2;
  }
  if (state.longEnd.length > 0) {
    const term = state.longEnd;
    const end = line.indexOf(term, i);
    if (end < 0) { pushToken(out, line.substring(i), S.Str); return; }
    pushToken(out, line.substring(i, end + term.length), S.Str);
    state.longEnd = '';
    i = end + term.length;
  }

  const first = firstNonSpace(line);

  while (i < n) {
    const cc = line.charCodeAt(i);
    const c = line.charAt(i);

    if (isSpaceCode(cc)) {
      let j = i + 1;
      while (j < n && isSpaceCode(line.charCodeAt(j))) j++;
      pushToken(out, line.substring(i, j), S.Plain);
      i = j;
      continue;
    }

    if (c === '/' && i + 1 < n) {
      const c2 = line.charAt(i + 1);
      if (c2 === '/') { pushToken(out, line.substring(i), S.Comment); return; }
      if (c2 === '*') {
        const end = line.indexOf('*/', i + 2);
        if (end < 0) {
          pushToken(out, line.substring(i), S.Comment);
          state.blockComment = true;
          return;
        }
        pushToken(out, line.substring(i, end + 2), S.Comment);
        i = end + 2;
        continue;
      }
    }

    if (c === '#' && i === first) {
      pushToken(out, line.substring(i), S.Meta);
      return;
    }

    if (c === '`') {
      const end = line.indexOf('`', i + 1);
      if (end < 0) {
        pushToken(out, line.substring(i), S.Str);
        state.longEnd = '`';
        return;
      }
      pushToken(out, line.substring(i, end + 1), S.Str);
      i = end + 1;
      continue;
    }

    if (c === 'r' && i + 1 < n) {
      const c2 = line.charAt(i + 1);
      if (c2 === '"' || c2 === '#') {
        let j = i + 1;
        let hashes = 0;
        while (j < n && line.charAt(j) === '#') { hashes++; j++; }
        if (j < n && line.charAt(j) === '"') {
          let term = '"';
          for (let t = 0; t < hashes; t++) term += '#';
          const end = line.indexOf(term, j + 1);
          if (end < 0) {
            pushToken(out, line.substring(i), S.Str);
            state.longEnd = term;
            return;
          }
          pushToken(out, line.substring(i, end + term.length), S.Str);
          i = end + term.length;
          continue;
        }
      }
    }

    if (c === '"' || c === '\'') {
      const end = scanQuoted(line, i, c);
      pushToken(out, line.substring(i, end), S.Str);
      i = end;
      continue;
    }

    if (isDigitCode(cc) || (c === '.' && i + 1 < n && isDigitCode(line.charCodeAt(i + 1)))) {
      const end = scanNumber(line, i);
      pushToken(out, line.substring(i, end), S.Num);
      i = end;
      continue;
    }

    if (isIdentStartCode(cc)) {
      const end = scanWord(line, i);
      const word = line.substring(i, end);
      pushToken(out, word, classifyWord(word, line, end));
      i = end;
      continue;
    }

    if (isPunctCode(cc)) {
      let j = i + 1;
      while (j < n && isPunctCode(line.charCodeAt(j))) {
        if (line.charAt(j) === '/' && j + 1 < n) {
          const c2 = line.charAt(j + 1);
          if (c2 === '/' || c2 === '*') break;
        }
        j++;
      }
      pushToken(out, line.substring(i, j), S.Punct);
      i = j;
      continue;
    }

    pushToken(out, c, S.Plain);
    i++;
  }
}

function scanHash(state, line, out) {
  const n = line.length;
  let i = 0;

  if (state.longEnd.length > 0) {
    const term = state.longEnd;
    const end = line.indexOf(term);
    if (end < 0) { pushToken(out, line, S.Str); return; }
    pushToken(out, line.substring(0, end + term.length), S.Str);
    state.longEnd = '';
    i = end + term.length;
  }

  const first = firstNonSpace(line);

  while (i < n) {
    const cc = line.charCodeAt(i);
    const c = line.charAt(i);

    if (isSpaceCode(cc)) {
      let j = i + 1;
      while (j < n && isSpaceCode(line.charCodeAt(j))) j++;
      pushToken(out, line.substring(i, j), S.Plain);
      i = j;
      continue;
    }

    if (c === '#') {
      if (i === first && line.startsWith('#!', i)) {
        pushToken(out, line.substring(i), S.Meta);
      } else {
        pushToken(out, line.substring(i), S.Comment);
      }
      return;
    }

    if (c === '"' || c === '\'') {
      const triple = c + c + c;
      if (line.startsWith(triple, i)) {
        const end = line.indexOf(triple, i + 3);
        if (end < 0) {
          pushToken(out, line.substring(i), S.Str);
          state.longEnd = triple;
          return;
        }
        pushToken(out, line.substring(i, end + 3), S.Str);
        i = end + 3;
        continue;
      }
      const end = scanQuoted(line, i, c);
      pushToken(out, line.substring(i, end), S.Str);
      i = end;
      continue;
    }

    if (c === '`') {
      const end = line.indexOf('`', i + 1);
      if (end < 0) { pushToken(out, line.substring(i), S.Str); return; }
      pushToken(out, line.substring(i, end + 1), S.Str);
      i = end + 1;
      continue;
    }

    if (isDigitCode(cc)) {
      const end = scanNumber(line, i);
      pushToken(out, line.substring(i, end), S.Num);
      i = end;
      continue;
    }

    if (isIdentStartCode(cc)) {
      const end = scanWord(line, i);
      const word = line.substring(i, end);
      let style = classifyWord(word, line, end);
      if (style === S.Plain && i === first && end < n && line.charAt(end) === ':') {
        style = S.Attr;
      }
      pushToken(out, word, style);
      i = end;
      continue;
    }

    if (isPunctCode(cc)) {
      let j = i + 1;
      while (j < n && isPunctCode(line.charCodeAt(j))) j++;
      pushToken(out, line.substring(i, j), S.Punct);
      i = j;
      continue;
    }

    pushToken(out, c, S.Plain);
    i++;
  }
}

function scanMarkup(state, line, out) {
  const n = line.length;
  let i = 0;

  if (state.blockComment) {
    const end = line.indexOf('-->');
    if (end < 0) { pushToken(out, line, S.Comment); return; }
    pushToken(out, line.substring(0, end + 3), S.Comment);
    state.blockComment = false;
    i = end + 3;
  }
  if (state.longEnd.length > 0) {
    const term = state.longEnd;
    const end = line.indexOf(term, i);
    if (end < 0) { pushToken(out, line.substring(i), S.Str); return; }
    pushToken(out, line.substring(i, end + term.length), S.Str);
    state.longEnd = '';
    i = end + term.length;
  }

  while (i < n) {
    if (state.inTag) {
      const next = scanTag(state, line, i, out);
      i = next > i ? next : i + 1;
      continue;
    }

    const c = line.charAt(i);

    if (c === '<') {
      if (line.startsWith('<!--', i)) {
        const end = line.indexOf('-->', i + 4);
        if (end < 0) {
          pushToken(out, line.substring(i), S.Comment);
          state.blockComment = true;
          return;
        }
        pushToken(out, line.substring(i, end + 3), S.Comment);
        i = end + 3;
        continue;
      }
      if (line.startsWith('<![CDATA[', i)) {
        const end = line.indexOf(']]>', i + 9);
        if (end < 0) {
          pushToken(out, line.substring(i), S.Str);
          state.longEnd = ']]>';
          return;
        }
        pushToken(out, line.substring(i, end + 3), S.Str);
        i = end + 3;
        continue;
      }
      if (line.startsWith('<!', i)) {
        const end = line.indexOf('>', i + 2);
        if (end < 0) { pushToken(out, line.substring(i), S.Meta); return; }
        pushToken(out, line.substring(i, end + 1), S.Meta);
        i = end + 1;
        continue;
      }

      const closing = i + 1 < n && line.charAt(i + 1) === '/';
      const nameStart = closing ? i + 2 : i + 1;
      if (nameStart < n && isAlphaCode(line.charCodeAt(nameStart))) {
        pushToken(out, closing ? '</' : '<', S.Punct);
        let j = nameStart;
        while (j < n && isTagNameCode(line.charCodeAt(j))) j++;
        pushToken(out, line.substring(nameStart, j), S.Tag);
        i = j;
        state.inTag = true;
        continue;
      }

      pushToken(out, '<', S.Punct);
      i++;
      continue;
    }

    if (c === '&') {
      const semi = line.indexOf(';', i + 1);
      if (semi > i + 1 && semi - i <= 12) {
        pushToken(out, line.substring(i, semi + 1), S.Meta);
        i = semi + 1;
        continue;
      }
    }

    let j = i + 1;
    while (j < n && line.charAt(j) !== '<' && line.charAt(j) !== '&') j++;
    pushToken(out, line.substring(i, j), S.Plain);
    i = j;
  }
}

function scanTag(state, line, i0, out) {
  const n = line.length;
  let i = i0;
  while (i < n) {
    const cc = line.charCodeAt(i);
    const c = line.charAt(i);

    if (isSpaceCode(cc)) {
      let j = i + 1;
      while (j < n && isSpaceCode(line.charCodeAt(j))) j++;
      pushToken(out, line.substring(i, j), S.Plain);
      i = j;
      continue;
    }
    if (c === '>') {
      pushToken(out, '>', S.Punct);
      state.inTag = false;
      return i + 1;
    }
    if (c === '/' || c === '=') {
      pushToken(out, c, S.Punct);
      i++;
      continue;
    }
    if (c === '"' || c === '\'') {
      const end = scanQuoted(line, i, c);
      pushToken(out, line.substring(i, end), S.Str);
      i = end;
      continue;
    }
    if (isIdentStartCode(cc) || c === '-') {
      const end = isIdentStartCode(cc) ? scanWord(line, i) : scanCssName(line, i);
      pushToken(out, line.substring(i, end), S.Attr);
      i = end;
      continue;
    }
    pushToken(out, c, S.Plain);
    i++;
  }
  return i;
}

function isHexColor(word) {
  const len = word.length;
  if (len !== 3 && len !== 4 && len !== 6 && len !== 8) return false;
  for (let i = 0; i < len; i++) {
    if (!isHexCode(word.charCodeAt(i))) return false;
  }
  return true;
}

function scanCss(state, line, out) {
  const n = line.length;
  let i = 0;

  if (state.blockComment) {
    const end = line.indexOf('*/');
    if (end < 0) { pushToken(out, line, S.Comment); return; }
    pushToken(out, line.substring(0, end + 2), S.Comment);
    state.blockComment = false;
    i = end + 2;
  }

  while (i < n) {
    const cc = line.charCodeAt(i);
    const c = line.charAt(i);

    if (isSpaceCode(cc)) {
      let j = i + 1;
      while (j < n && isSpaceCode(line.charCodeAt(j))) j++;
      pushToken(out, line.substring(i, j), S.Plain);
      i = j;
      continue;
    }

    if (c === '/' && i + 1 < n && line.charAt(i + 1) === '*') {
      const end = line.indexOf('*/', i + 2);
      if (end < 0) {
        pushToken(out, line.substring(i), S.Comment);
        state.blockComment = true;
        return;
      }
      pushToken(out, line.substring(i, end + 2), S.Comment);
      i = end + 2;
      continue;
    }

    if (c === '"' || c === '\'') {
      const end = scanQuoted(line, i, c);
      pushToken(out, line.substring(i, end), S.Str);
      i = end;
      continue;
    }

    if (c === '#') {
      let j = i + 1;
      while (j < n) {
        const cj = line.charCodeAt(j);
        if (isIdentPartCode(cj) || cj === 45) j++; else break;
      }
      const word = line.substring(i + 1, j);
      if (isHexColor(word)) {
        pushToken(out, line.substring(i, j), S.Num);
      } else if (word.length > 0) {
        pushToken(out, line.substring(i, j), S.Tag);
      } else {
        pushToken(out, '#', S.Punct);
        i++;
        continue;
      }
      i = j;
      continue;
    }

    if (c === '@') {
      let j = i + 1;
      while (j < n) {
        const cj = line.charCodeAt(j);
        if (isIdentPartCode(cj) || cj === 45) j++; else break;
      }
      if (j === i + 1) {
        pushToken(out, '@', S.Punct);
        i++;
        continue;
      }
      pushToken(out, line.substring(i, j), S.Meta);
      i = j;
      continue;
    }

    if (c === '!') {
      let j = i + 1;
      while (j < n && isAlphaCode(line.charCodeAt(j))) j++;
      if (j === i + 1) {
        pushToken(out, '!', S.Punct);
        i++;
        continue;
      }
      pushToken(out, line.substring(i, j), S.Keyword);
      i = j;
      continue;
    }

    if (isDigitCode(cc) || (c === '.' && i + 1 < n && isDigitCode(line.charCodeAt(i + 1)))) {
      let j = scanNumber(line, i);
      while (j < n && (isAlphaCode(line.charCodeAt(j)) || line.charAt(j) === '%')) j++;
      pushToken(out, line.substring(i, j), S.Num);
      i = j;
      continue;
    }

    if (c === '.' && i + 1 < n
      && (isAlphaCode(line.charCodeAt(i + 1)) || line.charAt(i + 1) === '-')) {
      const j = scanCssName(line, i + 1);
      pushToken(out, line.substring(i, j), S.Tag);
      i = j;
      continue;
    }

    if (isIdentStartCode(cc) || (c === '-' && i + 1 < n && isAlphaCode(line.charCodeAt(i + 1)))) {
      const end = scanCssName(line, i);
      let k = end;
      while (k < n && isSpaceCode(line.charCodeAt(k))) k++;
      const isProp = k < n && line.charAt(k) === ':';
      pushToken(out, line.substring(i, end), isProp ? S.Attr : S.Plain);
      i = end;
      continue;
    }

    if (isPunctCode(cc)) {
      let j = i + 1;
      while (j < n && isPunctCode(line.charCodeAt(j))) {
        if (line.charAt(j) === '/' && j + 1 < n && line.charAt(j + 1) === '*') break;
        j++;
      }
      pushToken(out, line.substring(i, j), S.Punct);
      i = j;
      continue;
    }

    pushToken(out, c, S.Plain);
    i++;
  }
}

function scanSql(state, line, out) {
  const n = line.length;
  let i = 0;

  if (state.blockComment) {
    const end = line.indexOf('*/');
    if (end < 0) { pushToken(out, line, S.Comment); return; }
    pushToken(out, line.substring(0, end + 2), S.Comment);
    state.blockComment = false;
    i = end + 2;
  }

  while (i < n) {
    const cc = line.charCodeAt(i);
    const c = line.charAt(i);

    if (isSpaceCode(cc)) {
      let j = i + 1;
      while (j < n && isSpaceCode(line.charCodeAt(j))) j++;
      pushToken(out, line.substring(i, j), S.Plain);
      i = j;
      continue;
    }

    if (c === '-' && i + 1 < n && line.charAt(i + 1) === '-') {
      pushToken(out, line.substring(i), S.Comment);
      return;
    }
    if (c === '/' && i + 1 < n && line.charAt(i + 1) === '*') {
      const end = line.indexOf('*/', i + 2);
      if (end < 0) {
        pushToken(out, line.substring(i), S.Comment);
        state.blockComment = true;
        return;
      }
      pushToken(out, line.substring(i, end + 2), S.Comment);
      i = end + 2;
      continue;
    }

    if (c === '\'') {
      let j = i + 1;
      let closed = false;
      while (j < n) {
        if (line.charAt(j) === '\'') {
          if (j + 1 < n && line.charAt(j + 1) === '\'') { j += 2; continue; }
          j++;
          closed = true;
          break;
        }
        j++;
      }
      if (!closed) j = n;
      pushToken(out, line.substring(i, j), S.Str);
      i = j;
      continue;
    }

    if (c === '"' || c === '`' || c === '[') {
      const close = c === '[' ? ']' : c;
      const end = line.indexOf(close, i + 1);
      if (end < 0) { pushToken(out, line.substring(i), S.Attr); return; }
      pushToken(out, line.substring(i, end + 1), S.Attr);
      i = end + 1;
      continue;
    }

    if (isDigitCode(cc) || (c === '.' && i + 1 < n && isDigitCode(line.charCodeAt(i + 1)))) {
      const end = scanNumber(line, i);
      pushToken(out, line.substring(i, end), S.Num);
      i = end;
      continue;
    }

    if (isIdentStartCode(cc)) {
      const end = scanWord(line, i);
      const word = line.substring(i, end);
      const hit = sqlWords().get(word.toUpperCase());
      pushToken(out, word, hit !== undefined ? hit : S.Plain);
      i = end;
      continue;
    }

    if (isPunctCode(cc)) {
      let j = i + 1;
      while (j < n && isPunctCode(line.charCodeAt(j))) {
        if (line.charAt(j) === '/' && j + 1 < n && line.charAt(j + 1) === '*') break;
        if (line.charAt(j) === '-' && j + 1 < n && line.charAt(j + 1) === '-') break;
        j++;
      }
      pushToken(out, line.substring(i, j), S.Punct);
      i = j;
      continue;
    }

    pushToken(out, c, S.Plain);
    i++;
  }
}

function scanData(state, line, out) {
  const n = line.length;
  let i = 0;

  if (state.blockComment) {
    const end = line.indexOf('*/');
    if (end < 0) { pushToken(out, line, S.Comment); return; }
    pushToken(out, line.substring(0, end + 2), S.Comment);
    state.blockComment = false;
    i = end + 2;
  }

  while (i < n) {
    const cc = line.charCodeAt(i);
    const c = line.charAt(i);

    if (isSpaceCode(cc)) {
      let j = i + 1;
      while (j < n && isSpaceCode(line.charCodeAt(j))) j++;
      pushToken(out, line.substring(i, j), S.Plain);
      i = j;
      continue;
    }

    if (c === '/' && i + 1 < n) {
      const c2 = line.charAt(i + 1);
      if (c2 === '/') { pushToken(out, line.substring(i), S.Comment); return; }
      if (c2 === '*') {
        const end = line.indexOf('*/', i + 2);
        if (end < 0) {
          pushToken(out, line.substring(i), S.Comment);
          state.blockComment = true;
          return;
        }
        pushToken(out, line.substring(i, end + 2), S.Comment);
        i = end + 2;
        continue;
      }
    }

    if (c === '"' || c === '\'') {
      const end = scanQuoted(line, i, c);
      let k = end;
      while (k < n && isSpaceCode(line.charCodeAt(k))) k++;
      const isKey = k < n && line.charAt(k) === ':';
      pushToken(out, line.substring(i, end), isKey ? S.Attr : S.Str);
      i = end;
      continue;
    }

    if (isDigitCode(cc) || (c === '-' && i + 1 < n && isDigitCode(line.charCodeAt(i + 1)))) {
      const end = scanNumber(line, i);
      pushToken(out, line.substring(i, end), S.Num);
      i = end;
      continue;
    }

    if (isIdentStartCode(cc)) {
      const end = scanWord(line, i);
      const word = line.substring(i, end);
      const isLit = word === 'true' || word === 'false' || word === 'null' ||
        word === 'True' || word === 'False' || word === 'Null';
      pushToken(out, word, isLit ? S.Keyword : S.Plain);
      i = end;
      continue;
    }

    if (isPunctCode(cc)) {
      let j = i + 1;
      while (j < n && isPunctCode(line.charCodeAt(j))) {
        if (line.charAt(j) === '/' && j + 1 < n) {
          const c2 = line.charAt(j + 1);
          if (c2 === '/' || c2 === '*') break;
        }
        j++;
      }
      pushToken(out, line.substring(i, j), S.Punct);
      i = j;
      continue;
    }

    pushToken(out, c, S.Plain);
    i++;
  }
}

function scanDiff(line, out) {
  if (line.length === 0) return;
  if (line.startsWith('+++') || line.startsWith('---') || line.startsWith('@@') ||
    line.startsWith('diff ') || line.startsWith('index ') ||
    line.startsWith('Index:') || line.startsWith('new file') ||
    line.startsWith('deleted file') || line.startsWith('old mode') ||
    line.startsWith('new mode') || line.startsWith('similarity index') ||
    line.startsWith('rename ')) {
    pushToken(out, line, S.Meta);
    return;
  }
  const c = line.charAt(0);
  if (c === '+') { pushToken(out, line, S.Str); return; }
  if (c === '-') { pushToken(out, line, S.Comment); return; }
  if (c === '\\') { pushToken(out, line, S.Meta); return; }
  pushToken(out, line, S.Plain);
}

// ---------------------------------------------------------------------------
// 对外接口（与 .ets 一致）
// ---------------------------------------------------------------------------

function familyOf(lang) {
  let name = String(lang).trim().toLowerCase();
  if (name.length === 0) return F.None;
  const brace = name.indexOf('{');
  if (brace >= 0) name = name.substring(0, brace);
  const space = name.indexOf(' ');
  if (space >= 0) name = name.substring(0, space);
  if (name.length === 0) return F.None;
  if (LANG_CLIKE.indexOf(name) >= 0) return F.CLike;
  if (LANG_HASH.indexOf(name) >= 0) return F.Hash;
  if (LANG_MARKUP.indexOf(name) >= 0) return F.Markup;
  if (LANG_CSS.indexOf(name) >= 0) return F.Css;
  if (LANG_SQL.indexOf(name) >= 0) return F.Sql;
  if (LANG_DATA.indexOf(name) >= 0) return F.Data;
  if (LANG_DIFF.indexOf(name) >= 0) return F.Diff;
  return F.None;
}

function supports(lang) {
  return familyOf(lang) !== F.None;
}

function tokenizeLines(lines, lang) {
  const family = familyOf(lang);
  const out = [];
  const state = newState();

  for (let li = 0; li < lines.length; li++) {
    const line = lines[li];
    const toks = [];
    if (line.length > 0) {
      if (family === F.CLike) scanCLike(state, line, toks);
      else if (family === F.Hash) scanHash(state, line, toks);
      else if (family === F.Markup) scanMarkup(state, line, toks);
      else if (family === F.Css) scanCss(state, line, toks);
      else if (family === F.Sql) scanSql(state, line, toks);
      else if (family === F.Data) scanData(state, line, toks);
      else if (family === F.Diff) scanDiff(line, toks);
      else pushToken(toks, line, S.Plain);
      fixTrailing(line, toks);
    }
    out.push(toks);
  }
  return out;
}

// ---------------------------------------------------------------------------
// 语料
// ---------------------------------------------------------------------------

const CORPUS = [];

function add(name, lang, lines) {
  CORPUS.push({ name: name, lang: lang, lines: lines });
}

// 1. JS：跨行块注释（第 2–5 行必须仍是 Comment）
add('js-multiline-comment', 'js', [
  'const a = 1;',
  '/*',
  ' * 这是注释的第二行',
  ' * 第三行，含 "字符串" 与 123',
  ' */',
  'const b = a + 2; // 行尾注释'
]);

// 2. JS：模板串跨行 + 插值 + 反引号
add('js-template-literal', 'ts', [
  'const sql = `',
  '  SELECT *',
  '  FROM t',
  '  WHERE name = \'x\'',
  '`;',
  'const n = 0x1f + 1_000 + .5 + 12n + 3.14e-2;'
]);

// 3. JS：正则字面量与 `//` 紧贴标点
add('js-punct-comment-edge', 'jsx', [
  'const re = /a\\/b/g; // 正则里的斜杠',
  'if (a<b && c>d) { x(); }/*tail*/y();'
]);

// 4. TS：泛型、装饰器、类型注解
add('ts-generics', 'tsx', [
  '@Component',
  'export class Foo<T extends object> implements Bar {',
  '  private readonly map: Map<string, number> = new Map();',
  '  render(): void { this.map.set(\'x\', 1); }',
  '}'
]);

// 5. Python：三引号 docstring 跨行
add('py-triple-quote', 'py', [
  'def hello(name):',
  '    """返回问候语。',
  '',
  '    第二段里 # 不是注释',
  '    """',
  '    return f"hi {name}"  # 这里是注释'
]);

// 6. Python：单引号串里的 `#` 不算注释
add('py-hash-in-string', 'python', [
  '# 行注释',
  'color = "#ff0000"',
  'x = 1  # trailing',
  'a, b = "a", \'b\''
]);

// 7. Bash：shebang、变量赋值、注释
add('bash-script', 'bash', [
  '#!/usr/bin/env bash',
  'set -euo pipefail',
  'NAME="纸见"   # 名称',
  'for f in *.md; do',
  '  echo "$f" | grep -v "^#"',
  'done'
]);

// 8. YAML：行首键、`#` 注释、`#fff` 在 YAML 里也是注释
add('yaml-config', 'yaml', [
  'name: zhijian',
  'version: 1.2.0',
  '# 这是注释',
  'theme:',
  '  accent: "#0A59F7"   # 也可以是颜色',
  '  tags: [a, b, c]'
]);

// 9. CSS：`#fff` 是颜色，`#note` 是选择器，注释跨行
add('css-hex-selector', 'css', [
  '/* 多行注释',
  '   第二行 */',
  '#app .card, #note {',
  '  color: #fff;',
  '  background: #0A59F7;',
  '  border: 1px solid rgba(0, 0, 0, .5);',
  '  --gap: 2rem;',
  '}',
  '@media (max-width: 600px) { .card { padding: 0.5em !important; } }'
]);

// 10. HTML：注释跨行、多行属性、实体
add('html-multiline', 'html', [
  '<!DOCTYPE html>',
  '<!--',
  '  多行注释，里面 <div> 不算标签',
  '-->',
  '<div class="a"',
  '     data-id=\'7\' hidden>',
  '  <p>a &lt; b&nbsp;&amp; c</p>',
  '  <img src="x.png" />',
  '</div>'
]);

// 11. XML：CDATA 跨行
add('xml-cdata', 'xml', [
  '<?xml version="1.0"?>',
  '<root>',
  '<![CDATA[',
  '  x < y && z > 0',
  ']]>',
  '<child id="1"/>',
  '</root>'
]);

// 12. JSON：键/值、字符串里的冒号、字面量
add('json-nested', 'json', [
  '{',
  '  "name": "zhijian",',
  '  "url": "https://a.b/c:d",',
  '  "n": -12.5e3,',
  '  "ok": true,',
  '  "nil": null,',
  '  "list": ["a", "b"]',
  '}'
]);

// 13. JSON5：注释 + 尾逗号
add('json5-comments', 'json5', [
  '// 单行',
  '{',
  '  /* 块注释',
  '     跨行 */',
  '  key: \'v\',',
  '}'
]);

// 14. diff：头部 Meta、+/- 整行、\ No newline
add('diff-patch', 'diff', [
  'diff --git a/a.md b/a.md',
  'index 111..222 100644',
  '--- a/a.md',
  '+++ b/a.md',
  '@@ -1,3 +1,3 @@',
  ' unchanged',
  '-删除的行',
  '+新增的行',
  '\\ No newline at end of file'
]);

// 15. SQL：`--` 注释、块注释、`''` 转义、关键字不分大小写
add('sql-mixed', 'sql', [
  '-- 建表',
  'CREATE TABLE t (',
  '  id INTEGER PRIMARY KEY,   /* 主键 */',
  "  name VARCHAR(32) NOT NULL DEFAULT 'it''s'",
  ');',
  'select count(*) from t where name like \'%a%\' -- 尾注'
]);

// 16. Rust：原始串跨行 + 生命周期 + 宏
add('rust-raw-string', 'rust', [
  'fn main() {',
  '    let re = r#"',
  '        \\d+ "quoted" ',
  '    "#;',
  '    let s: &\'static str = "x";',
  '    println!("{}", s);',
  '}'
]);

// 17. Go：反引号原始串跨行
add('go-raw-string', 'go', [
  'package main',
  'func main() {',
  '    q := `SELECT *',
  '    FROM t`',
  '    fmt.Println(q, 0b1010, 3.5e9)',
  '}'
]);

// 18. Java：注解、泛型、字符串里的转义
add('java-annotations', 'java', [
  '@Override',
  'public <T extends Comparable<T>> T max(List<T> xs) {',
  '    String s = "a\\"b";',
  '    return xs.get(0);',
  '}'
]);

// 19. C：预处理、十六进制、后缀、行尾空白
add('c-preprocessor', 'c', [
  '#include <stdio.h>',
  '#define N 0xFFu',
  'int main(void) {',
  '    unsigned long x = 10UL;   ',
  '    printf("%d\\n", x);',
  '    return 0;',
  '}'
]);

// 20. 空行 / 深缩进 / 纯空白 / 行尾空白 / 制表符
add('whitespace-shapes', 'js', [
  '',
  '    ',
  '\t if (x) {',
  '        y();   ',
  '',
  'end  '
]);

// 21. 未识别语言：supports() 必须 false（分词退化为纯文本）
add('plaintext-fallback', 'text', [
  '这不是代码',
  '  第二行 # 也不是注释',
  ''
]);

// 22. scss（cLike 族）：`//` 与 `/* */` 同时存在
add('scss-mixed', 'scss', [
  '// 行注释',
  '.a {',
  '  /* 块注释 */',
  '  color: #fff;',
  '}'
]);

// ---------------------------------------------------------------------------
// 断言
// ---------------------------------------------------------------------------

let pass = 0;
let fail = 0;
const failures = [];

function ok(cond, msg) {
  if (cond) { pass++; } else { fail++; failures.push(msg); }
}

function dump(tokens) {
  return tokens.map(t => t.text + '{' + t.style + '}').join(' ');
}

// A. 拼接不变式 + 行数
for (const c of CORPUS) {
  const toks = tokenizeLines(c.lines, c.lang);
  ok(toks.length === c.lines.length, c.name + ': 行数 ' + toks.length + ' !== ' + c.lines.length);
  for (let i = 0; i < c.lines.length; i++) {
    const joined = toks[i].map(t => t.text).join('');
    if (joined !== c.lines[i]) {
      ok(false, c.name + ' 行' + (i + 1) + ' 拼接不符\n  期望: ' + JSON.stringify(c.lines[i]) +
        '\n  实得: ' + JSON.stringify(joined) + '\n  片段: ' + dump(toks[i]));
    } else {
      ok(true, '');
    }
    // 空行必须是空数组
    if (c.lines[i].length === 0) {
      ok(toks[i].length === 0, c.name + ' 行' + (i + 1) + ': 空行应返回空数组');
    }
    // 片段不允许是空串 token
    for (let t = 0; t < toks[i].length; t++) {
      if (toks[i][t].text.length === 0) {
        ok(false, c.name + ' 行' + (i + 1) + ': 出现零长 token');
      }
    }
  }
}

// B. 定点断言：跨行状态与族语义
function stylesOf(lang, lines, lineIdx) {
  return tokenizeLines(lines, lang)[lineIdx];
}
function styleAt(lang, lines, lineIdx, text) {
  const toks = stylesOf(lang, lines, lineIdx);
  for (const t of toks) {
    if (t.text === text) return t.style;
  }
  return -1;
}
function allStyle(lang, lines, lineIdx, style) {
  const toks = stylesOf(lang, lines, lineIdx);
  return toks.length > 0 && toks.every(t => t.style === style || t.style === S.Plain);
}

// js 多行注释：第 2–5 行是 Comment
{
  const lines = [ 'a();', '/*', ' * 第二行', ' * 第三行', ' */', 'b();' ];
  const t = tokenizeLines(lines, 'js');
  ok(t[1][0].style === S.Comment, 'js: `/*` 起首行应为 Comment');
  ok(t[2][0].style === S.Comment, 'js: 注释第 2 行应为 Comment（跨行状态丢了）');
  ok(t[3][0].style === S.Comment, 'js: 注释第 3 行应为 Comment');
  ok(t[4][0].style === S.Comment, 'js: 注释结束行应为 Comment');
  ok(t[5][0].style !== S.Comment, 'js: 注释后一行不应是 Comment');
}

// js 模板串：中间行是 Str
{
  const lines = ['const s = `', '  SELECT 1', '`;'];
  const t = tokenizeLines(lines, 'js');
  ok(t[1][0].style === S.Str, 'js: 模板串中间行应为 Str');
  ok(t[2][0].style === S.Str, 'js: 模板串收尾行应以 Str 开头');
}

// python 三引号：中间行 Str
{
  const lines = ['x = """', '  不是注释 # 也不是', '"""'];
  const t = tokenizeLines(lines, 'py');
  ok(t[1][0].style === S.Str, 'py: 三引号中间行应为 Str');
}

// go 反引号
{
  const lines = ['q := `', 'line two', '`'];
  const t = tokenizeLines(lines, 'go');
  ok(t[1][0].style === S.Str, 'go: 反引号原始串中间行应为 Str');
}

// rust r#"…"#
{
  const lines = ['let s = r#"', 'raw "x"', '"#;'];
  const t = tokenizeLines(lines, 'rust');
  ok(t[1][0].style === S.Str, 'rust: r#" 原始串中间行应为 Str');
}

// css：`#fff` 是 Num，`#note` 是 Tag，都不是 Comment
{
  const lines = ['a { color: #fff; }', '#note { x: 1 }', '/* c */'];
  const t = tokenizeLines(lines, 'css');
  ok(styleAt('css', lines, 0, '#fff') === S.Num, 'css: #fff 应为 Num（颜色），实得 ' + styleAt('css', lines, 0, '#fff'));
  ok(styleAt('css', lines, 1, '#note') === S.Tag, 'css: #note 应为 Tag（选择器）');
  for (const tok of t[0]) {
    ok(tok.style !== S.Comment, 'css: 行内不该出现 Comment（#fff 被当成注释了）');
  }
}

// python 行首 # 是 Comment，但字符串里的 # 不是
{
  const lines = ['# comment', 'x = "#fff"'];
  ok(styleAt('py', lines, 0, '# comment') === S.Comment, 'py: 行首 # 应为 Comment');
  const t = tokenizeLines(lines, 'py');
  ok(t[1].some(x => x.style === S.Str && x.text === '"#fff"'), 'py: 字符串里的 # 应留在 Str 里');
}

// yaml：行首 `key:` → Attr，`#` → Comment
{
  const lines = ['name: zhijian', '  # 注释', 'version: 1.0'];
  ok(styleAt('yaml', lines, 0, 'name') === S.Attr, 'yaml: 行首键应为 Attr，实得 ' + styleAt('yaml', lines, 0, 'name'));
  ok(styleAt('yaml', lines, 1, '# 注释') === S.Comment, 'yaml: # 应为 Comment');
  ok(styleAt('yaml', lines, 2, 'version') === S.Attr, 'yaml: 缩进后的键也应认（first 判定看空白）');
}

// markup：Tag / Attr / Str / Comment 四层
{
  const lines = ['<a href="x" data-id=\'1\'>t</a>'];
  const t = tokenizeLines(lines, 'html');
  ok(styleAt('html', lines, 0, 'a') === S.Tag, 'html: 标签名应为 Tag');
  ok(styleAt('html', lines, 0, 'href') === S.Attr, 'html: 属性名应为 Attr');
  ok(styleAt('html', lines, 0, '"x"') === S.Str, 'html: 属性值应为 Str');
}

// markup 注释跨行
{
  const lines = ['<!--', '  inside <b>', '-->', '<p>x</p>'];
  const t = tokenizeLines(lines, 'html');
  ok(t[1][0].style === S.Comment, 'html: 注释中间行应为 Comment');
  ok(t[3][0].style === S.Punct, 'html: 注释之后应恢复标签解析');
}

// json：键 Attr、值 Str、字面量 Keyword
{
  const lines = ['{ "a": "b:c", "n": 1, "t": true }'];
  const t = tokenizeLines(lines, 'json');
  ok(styleAt('json', lines, 0, '"a"') === S.Attr, 'json: 键应为 Attr');
  ok(styleAt('json', lines, 0, '"b:c"') === S.Str, 'json: 含冒号的值仍应为 Str');
  ok(styleAt('json', lines, 0, 'true') === S.Keyword, 'json: true 应为 Keyword');
  ok(styleAt('json', lines, 0, '1') === S.Num, 'json: 数字应为 Num');
}

// diff：整行语义
{
  const lines = ['--- a/x', '+++ b/x', '@@ -1 +1 @@', '-old', '+new', ' ctx', '\\ No newline'];
  const t = tokenizeLines(lines, 'diff');
  ok(t[0][0].style === S.Meta, 'diff: --- 头部应为 Meta');
  ok(t[1][0].style === S.Meta, 'diff: +++ 头部应为 Meta');
  ok(t[2][0].style === S.Meta, 'diff: @@ 应为 Meta');
  ok(t[3][0].style === S.Comment, 'diff: - 行应为 Comment');
  ok(t[4][0].style === S.Str, 'diff: + 行应为 Str');
  ok(t[5][0].style === S.Plain, 'diff: 上下文行应为 Plain');
  ok(t[6][0].style === S.Meta, 'diff: \\ No newline 应为 Meta');
}

// sql：关键字大小写不敏感、-- 注释
{
  const lines = ['select 1 -- x', 'SELECT 2'];
  const t = tokenizeLines(lines, 'sql');
  ok(styleAt('sql', lines, 0, 'select') === S.Keyword, 'sql: 小写关键字应识别');
  ok(styleAt('sql', lines, 1, 'SELECT') === S.Keyword, 'sql: 大写关键字应识别');
  ok(t[0].some(x => x.style === S.Comment && x.text === '-- x'), 'sql: -- 后应为 Comment');
}

// 行尾空白：必须在 Plain token 里（可以是一段 Plain 的尾巴，但绝不能藏在彩色 token 中）
{
  const lines = ['// hi   ', 'int x = 1;   ', 'plain   '];
  const t = tokenizeLines(lines, 'c');
  for (let i = 0; i < lines.length; i++) {
    const last = t[i][t[i].length - 1];
    ok(last.style === S.Plain && last.text.endsWith('   '),
      '行尾空白: 行' + (i + 1) + ' 尾 token 应为 Plain 且以 "   " 结尾，实得 ' +
      last.style + ' ' + JSON.stringify(last.text));
  }
  // 彩色 token 上的行尾空白必须被**切**出来，不能整个留在彩色片段里
  ok(t[0][0].style === S.Comment && t[0][0].text === '// hi',
    '行尾空白: 注释后的空白应切出 Plain，实得 ' + JSON.stringify(t[0][0].text));
  ok(t[1][t[1].length - 1].style === S.Plain && t[1][t[1].length - 1].text === '   ' &&
    t[1][t[1].length - 2].text === ';',
    '行尾空白: 标点后的空白应单独成 Plain token，实得 ' + dump(t[1]));
}

// supports()
{
  const yes = ['js', 'ts', 'tsx', 'java', 'c', 'cpp', 'cs', 'go', 'rust', 'kotlin', 'swift',
    'php', 'scala', 'dart', 'scss', 'less', 'py', 'rb', 'sh', 'bash', 'yaml', 'yml', 'toml',
    'ini', 'dockerfile', 'makefile', 'r', 'pl', 'ps1', 'nginx', 'cmake', 'gitignore',
    'html', 'xml', 'svg', 'vue', 'svelte', 'hbs', 'xaml', 'css', 'sql', 'mysql', 'sqlite',
    'json', 'json5', 'geojson', 'diff', 'patch', 'JS', ' TypeScript ', 'js{1-3}'];
  for (const l of yes) ok(supports(l) === true, 'supports("' + l + '") 应为 true');
  const no = ['text', 'txt', 'plain', 'log', 'output', '', 'mermaid', 'echarts', 'foo', 'cobol'];
  for (const l of no) ok(supports(l) === false, 'supports("' + l + '") 应为 false');
}

// 所有族 + 所有行都必须满足不变式（含非法/畸形输入）
{
  const nasty = [
    '*/ stray close', '/* unterminated', '"unterminated', '\'unterminated',
    '`unterminated', 'r#"unterminated', '<div class="x', '<!-- unterminated',
    '&&&;;;', '\\\\\\', '0x', '1e', '.', '-', '#', '@', '!', '<!-->', '<![CDATA[',
    ']]>', '"""', '\'\'\'', '{{ }}', '\\u0000'
  ];
  const langs = ['js', 'py', 'html', 'css', 'sql', 'json', 'diff'];
  for (const l of langs) {
    const t = tokenizeLines(nasty, l);
    ok(t.length === nasty.length, 'nasty/' + l + ': 行数不符');
    for (let i = 0; i < nasty.length; i++) {
      const joined = t[i].map(x => x.text).join('');
      ok(joined === nasty[i], 'nasty/' + l + ' 行' + (i + 1) + ': ' + JSON.stringify(nasty[i]) + ' → ' + JSON.stringify(joined));
    }
  }
}

// ---------------------------------------------------------------------------
// 性能：2000 行
// ---------------------------------------------------------------------------

const big = [];
for (let i = 0; i < 2000; i++) {
  const k = i % 8;
  if (k === 0) big.push('  // 第 ' + i + ' 行注释');
  else if (k === 1) big.push('  const v' + i + ' = "str' + i + '";');
  else if (k === 2) big.push('  function f' + i + '(a, b) { return a + b * ' + i + '; }');
  else if (k === 3) big.push('  if (x' + i + ' > 0 && y < 10) { z(); }');
  else if (k === 4) big.push('  /*');
  else if (k === 5) big.push('   * 块注释 ' + i);
  else if (k === 6) big.push('   */');
  else big.push('  for (let i = 0; i < ' + i + '; i++) { acc += i; }');
}
const t0 = process.hrtime.bigint();
const bigToks = tokenizeLines(big, 'js');
const t1 = process.hrtime.bigint();
const coldMs = Number(t1 - t0) / 1e6;

// 暖机后再测三次，取最小值（首次包含关键字表构建）
let warmMs = coldMs;
for (let r = 0; r < 3; r++) {
  const w0 = process.hrtime.bigint();
  tokenizeLines(big, 'js');
  const w1 = process.hrtime.bigint();
  const v = Number(w1 - w0) / 1e6;
  if (v < warmMs) warmMs = v;
}
let bigOk = bigToks.length === big.length;
for (let i = 0; i < big.length && bigOk; i++) {
  if (bigToks[i].map(x => x.text).join('') !== big[i]) bigOk = false;
}
ok(bigOk, '2000 行性能语料的拼接不变式');
console.log('性能：2000 行 cLike 分词 首次 ' + coldMs.toFixed(2) + ' ms / 暖机最小 ' +
  warmMs.toFixed(2) + ' ms，token 总数 ' + bigToks.reduce((a, b) => a + b.length, 0));

// ---------------------------------------------------------------------------
// 汇总
// ---------------------------------------------------------------------------

console.log('');
if (fail === 0) {
  console.log('PASS  断言 ' + pass + ' 条，语料 ' + CORPUS.length + ' 份，全部满足拼接不变式');
  process.exit(0);
} else {
  console.log('FAIL  ' + fail + ' / ' + (pass + fail));
  for (const f of failures.slice(0, 30)) console.log('  - ' + f);
  process.exit(1);
}
