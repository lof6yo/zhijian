#!/usr/bin/env node
/**
 * tools/md-parse-check.js
 * =======================
 *
 * Runs the **real** ArkTS parser (`entry/src/main/ets/markdown/MdParser.ets`) under
 * plain Node and asserts its behaviour against `tools/corpus/*.md`.
 *
 * ## Why this is not a JS port
 *
 * A hand-written JS copy of the parser would test the copy, not the shipped code —
 * the two drift apart on the first edit and the harness starts lying. Instead this
 * script does the pragmatic thing:
 *
 * 1. copies `MdTypes.ets` / `MdParser.ets` into `tools/.tmp/` as `.mts` files and
 *    rewrites the one relative import (`'./MdTypes'` → `'./MdTypes.mts'`);
 * 2. generates `tools/.tmp/runner.mts` — the assertions below, as data — and runs it
 *    with `node --experimental-transform-types` (Node's built-in type stripping,
 *    which also transpiles the `enum`s; no TypeScript install required);
 * 3. forwards the exit code.
 *
 * So the file under test is byte-for-byte the file that ships (minus the import
 * specifier). The only thing not covered is ArkTS's own checker — that is
 * `devecocli check arkts`, which is a separate gate.
 *
 * ## Usage
 *
 *     node tools/md-parse-check.js            # assert everything
 *     node tools/md-parse-check.js --verbose  # also dump every block of every case
 *
 * Requires Node >= 22.7 (type stripping). `tools/.tmp/` is scratch output.
 *
 * Expectations are documented for humans in `tools/corpus/EXPECTED.md`; the arrays
 * below are the executable form of that document.
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const ROOT = path.resolve(__dirname, '..');
const MD_DIR = path.join(ROOT, 'entry', 'src', 'main', 'ets', 'markdown');
const TMP = path.join(__dirname, '.tmp');
const CORPUS = path.join(__dirname, 'corpus');
const VERBOSE = process.argv.indexOf('--verbose') >= 0;

// ---------------------------------------------------------------------------
// Block expectations, one entry per corpus file.
//
// Every entry checks the block **sequence**: count first, then the fields named on
// each expected block. Omitted fields are not checked, so an expectation states only
// what the case is actually about.
//
// Fields: kind, plain, level, anchor, lang, code, hl, aligns, cols, rows,
//         indent, ordered, seq, marker, task, quoteDepth, callout, srcLine
// ---------------------------------------------------------------------------

const CORPUS_CASES = [
  {
    file: '01-atx-heading.md',
    about: 'ATX 标题：级别、#后必须有空格、7 个井号不是标题、收尾井号、显式锚点',
    blocks: [
      { kind: 'Heading', level: 1, plain: '一级标题' },
      { kind: 'Heading', level: 2, plain: '二级标题' },
      { kind: 'Paragraph', plain: '####### 七个井号不是标题' },
      { kind: 'Paragraph', plain: '#没有空格不是标题' },
      { kind: 'Heading', level: 6, plain: '六级', anchor: 'six' },
      { kind: 'Heading', level: 2, plain: '收尾井号' }
    ]
  },
  {
    file: '02-setext-vs-divider.md',
    about: '紧跟文字行的 --- 是 setext 下划线（标题），空行之后的 --- 才是分割线',
    blocks: [
      { kind: 'Heading', level: 2, plain: '标题行' },
      { kind: 'Paragraph', plain: '段落一' },
      { kind: 'Divider' },
      { kind: 'Paragraph', plain: '段落二' }
    ]
  },
  {
    file: '03-table.md',
    about: '表格必须有分隔行；对齐；\\| 转义；缺分隔行退回段落',
    blocks: [
      { kind: 'Table', aligns: [0, 1, 2], cols: 3, rows: 3 },
      { kind: 'Paragraph', plain: '没有分隔行的表格 | 1 | 2 | | 3 | 4 |' },
      { kind: 'Paragraph', plain: '竖线转义' },
      { kind: 'Table', aligns: [0], cols: 1, rows: 2, plain: '列 a | b' }
    ]
  },
  {
    file: '04-fence.md',
    about: '围栏：语言名 + {1,3-4} 行号、~~~、图表语言、未闭合吃到文末',
    blocks: [
      {
        kind: 'Code',
        lang: 'js',
        hl: [1, 3, 4],
        code: 'const a = 1;\nconst b = 2;\nconst c = 3;\nconst d = 4;'
      },
      { kind: 'Code', lang: '', code: 'tilde fence' },
      { kind: 'Chart', lang: 'mermaid', code: 'graph TD; A-->B;' },
      { kind: 'Code', lang: '', code: '未闭合的围栏\n还有一行' }
    ]
  },
  {
    file: '05-quote-callout.md',
    about: '引用 / 嵌套引用 / 提示块（大写才认）/ [!note] 小写按普通引用',
    blocks: [
      { kind: 'Paragraph', plain: '引用一段', quoteDepth: 1 },
      { kind: 'Paragraph', plain: '第二段', quoteDepth: 1 },
      { kind: 'Callout', callout: 'Note', plain: '提示内容' },
      { kind: 'Paragraph', plain: '[!note] 小写不算提示块', quoteDepth: 1 },
      { kind: 'Paragraph', plain: '嵌套引用', quoteDepth: 2 }
    ]
  },
  {
    file: '06-list.md',
    about: '列表：缩进 ≥2 = 一层、起始序号、1) 形式、任务勾选、续行归入该项',
    blocks: [
      { kind: 'ListItem', plain: '第一项', indent: 0, ordered: false },
      { kind: 'ListItem', plain: '第二项', indent: 0 },
      { kind: 'ListItem', plain: '嵌套项', indent: 1 },
      { kind: 'ListItem', plain: '更深', indent: 2 },
      { kind: 'ListItem', plain: '第三项起', indent: 0, ordered: true, seq: 3 },
      { kind: 'ListItem', plain: '括号形式', indent: 0, ordered: true, seq: 1, marker: '1)' },
      { kind: 'ListItem', plain: '待办', task: 'Todo' },
      { kind: 'ListItem', plain: '已完成', task: 'Done' },
      { kind: 'ListItem', plain: '也算完成', task: 'Done' },
      { kind: 'ListItem', plain: '星号', marker: '*' },
      { kind: 'ListItem', plain: '加号', marker: '+' },
      { kind: 'ListItem', plain: '续行第一行 续行第二行' }
    ]
  },
  {
    file: '07-inline.md',
    about: '行内规则的块级结果：plain 必须是行内拼回去的文本，标记不残留',
    blocks: [
      { kind: 'Paragraph', plain: '粗体 和 斜体 和 粗斜体' },
      { kind: 'Paragraph', plain: '** 内侧有空格 ** 不生效' },
      { kind: 'Paragraph', plain: '**粗* 数量不对称' },
      { kind: 'Paragraph', plain: '行内代码 和 含 ` 反引号' },
      { kind: 'Paragraph', plain: '删除线 和 高亮' },
      { kind: 'Paragraph', plain: '链接 和 图' },
      { kind: 'Paragraph', plain: 'x^2 行内公式' },
      { kind: 'Paragraph', plain: '上标 和 下标' },
      { kind: 'Paragraph', plain: '转义 * 不是强调' },
      { kind: 'Paragraph', plain: 'snake_case_name 不应当变斜体' }
    ]
  },
  {
    file: '08-frontmatter.md',
    about: 'YAML front matter 整段跳过；首块 srcLine 仍是原文件真实行号；脚注定义与引用',
    blocks: [
      { kind: 'Heading', level: 1, plain: '真标题', srcLine: 5 },
      { kind: 'Paragraph', plain: '脚注引用n1。', srcLine: 7 },
      { kind: 'Paragraph', plain: '注释内容', srcLine: 9 }
    ],
    outline: [{ level: 1, text: '真标题', blockIndex: 0, seq: 1, anchor: '' }],
    notes: [{ no: 1, label: 'n1', text: '注释内容', blockIndex: 2 }]
  },
  {
    file: '09-paragraph-breaks.md',
    about: '段内软换行连成一个空格；行尾两个空格是硬换行（行内文本里的 \\n）',
    blocks: [
      { kind: 'Paragraph', plain: '第一行 第二行' },
      { kind: 'Paragraph', plain: '硬换行\n下一行' }
    ]
  },
  {
    file: '10-math.md',
    about: '$$ 公式块；未闭合也产出 Math 块',
    blocks: [
      { kind: 'Math', code: 'E = mc^2' },
      { kind: 'Math', code: '未闭合' }
    ]
  },
  {
    file: '11-chart.md',
    about: '图表语言名的围栏 → Chart 块，code 是原始图定义（缩进保留）',
    blocks: [{ kind: 'Chart', lang: 'mermaid', code: 'graph TD\n  A --> B' }]
  },
  {
    file: '12-garbage.md',
    about: '畸形输入：一个都不能抛异常，也不能吞掉文本',
    blocks: [
      { kind: 'Paragraph', plain: '#######' },
      { kind: 'Paragraph', plain: '|||' },
      { kind: 'Paragraph', plain: '[', quoteDepth: 1 },
      { kind: 'Paragraph', plain: '**未闭合粗体' },
      { kind: 'Paragraph', plain: '`未闭合代码' },
      { kind: 'Paragraph', plain: '[链接](' },
      { kind: 'Paragraph', plain: '</>' }
    ]
  },
  {
    file: '13-image.md',
    about: '独立成段的图片保留 Image 行内；与文字混排的图片降级成 alt 文本',
    blocks: [
      { kind: 'Paragraph', plain: '独立图', inlines: [{ kind: 'Image', text: '独立图' }] },
      {
        kind: 'Paragraph',
        plain: '文字里 行内图 混排',
        inlines: [
          { kind: 'Plain', text: '文字里 ' },
          { kind: 'Plain', text: '行内图' },
          { kind: 'Plain', text: ' 混排' }
        ]
      }
    ]
  }
];

// ---------------------------------------------------------------------------
// Inline expectations (the AST is asserted node by node, not just as plain text).
// Omitted fields default to Plain text / no styling / no href / num 0.
// ---------------------------------------------------------------------------

const INLINE_CASES = [
  { text: '**粗**', about: '粗体：单一文本片段带 bold 标志',
    out: [{ kind: 'Strong', text: '粗', bold: true }] },
  { text: '** 粗 **', about: '内侧贴空格不配对，整行保持原文',
    out: [{ text: '** 粗 **' }] },
  { text: '**粗*', about: '数量不对称：整行不加粗',
    out: [{ text: '**粗*' }] },
  { text: '***粗***', about: '粗斜体',
    out: [{ kind: 'Strong', text: '粗', bold: true, italic: true }] },
  { text: '*斜*', about: '斜体',
    out: [{ kind: 'Em', text: '斜', italic: true }] },
  { text: '_斜_', about: '下划线强调',
    out: [{ kind: 'Em', text: '斜', italic: true }] },
  { text: 'a_b_c', about: '词内 _ 不是强调',
    out: [{ text: 'a_b_c' }] },
  { text: '前**粗**后', about: '强调两侧都有文本',
    out: [{ text: '前' }, { kind: 'Strong', text: '粗', bold: true }, { text: '后' }] },
  { text: '**a *b* c**', about: '粗体里的斜体：继承为平级片段（外层 Plain+bold，内层带两种种类与标志）',
    out: [{ text: 'a ', bold: true }, { kind: 'Em', text: 'b', bold: true, italic: true }, { text: ' c', bold: true }] },
  { text: '**a\n\nb**', about: '不跨空行配对',
    out: [{ text: '**a\n\nb**' }] },
  { text: '`a*b*c`', about: '行内代码里不解析强调',
    out: [{ kind: 'Code', text: 'a*b*c', code: true }] },
  { text: '``a`b``', about: '多反引号代码，内含单个反引号',
    out: [{ kind: 'Code', text: 'a`b', code: true }] },
  { text: '~删~', about: '单波浪线是下标，不是删除线',
    out: [{ kind: 'Sub', text: '删' }] },
  { text: '~~删~~', about: '删除线',
    out: [{ kind: 'Strike', text: '删', strike: true }] },
  { text: '==高==', about: '高亮',
    out: [{ kind: 'Mark', text: '高' }] },
  { text: '^上^', about: '上标',
    out: [{ kind: 'Sup', text: '上' }] },
  { text: '[链](https://a.b/c)', about: '链接',
    out: [{ kind: 'Link', text: '链', href: 'https://a.b/c' }] },
  { text: '![alt](i.png)', about: '图片（行内退化成 alt，块级由段落承载）',
    out: [{ kind: 'Image', text: 'alt', href: 'i.png' }] },
  { text: '\\*不是强调\\*', about: '反斜杠转义',
    out: [{ text: '*不是强调*' }] },
  { text: '\\q', about: '不可转义字符保留反斜杠',
    out: [{ text: '\\q' }] },
  { text: '$x^2$', about: '行内公式',
    out: [{ kind: 'MathInline', text: 'x^2' }] },
  { text: '[^n1]', about: '脚注引用（无定义 → num 0）',
    out: [{ kind: 'FootnoteRef', text: 'n1', href: '', num: 0 }] },
  { text: '***', about: '孤立的 *** 原样保留',
    out: [{ text: '***' }] },
  { text: '\\`code\\`', about: '转义的反引号不开启代码段',
    out: [{ text: '`code`' }] }
];

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function readModule(name) {
  return fs.readFileSync(path.join(MD_DIR, name), 'utf8');
}

function buildTmpModules() {
  fs.mkdirSync(TMP, { recursive: true });
  const types = readModule('MdTypes.ets');
  const parser = readModule('MdParser.ets');

  // Node's type stripping cannot tell an interface from a value in an import list,
  // so type-only names must move to `import type`. Classify them by looking at what
  // MdTypes.ets actually declares, not by a hardcoded list that would rot.
  const typeNames = new Set();
  const declRe = /export\s+interface\s+([A-Za-z0-9_]+)/g;
  let decl = declRe.exec(types);
  while (decl !== null) {
    typeNames.add(decl[1]);
    decl = declRe.exec(types);
  }
  const importRe = /import\s*\{([\s\S]*?)\}\s*from\s*'\.\/MdTypes';/;
  const match = importRe.exec(parser);
  if (match === null) {
    throw new Error("MdParser.ets 的 import 形式变了，无法把它接进 Node runner");
  }
  const names = match[1].split(',').map((s) => s.trim()).filter((s) => s.length > 0);
  const typeOnly = names.filter((n) => typeNames.has(n));
  const values = names.filter((n) => !typeNames.has(n));
  const rewritten = "import type { " + typeOnly.join(', ') + " } from './MdTypes.mts';\n" +
    "import { " + values.join(', ') + " } from './MdTypes.mts';";
  const patched = parser.substring(0, match.index) + rewritten + parser.substring(match.index + match[0].length);

  fs.writeFileSync(path.join(TMP, 'MdTypes.mts'), types, 'utf8');
  fs.writeFileSync(path.join(TMP, 'MdParser.mts'), patched, 'utf8');
}

function corpusSource(file) {
  const full = path.join(CORPUS, file);
  if (!fs.existsSync(full)) {
    throw new Error('缺少语料文件 tools/corpus/' + file);
  }
  return fs.readFileSync(full, 'utf8');
}

function buildRunner() {
  const cases = CORPUS_CASES.map((c) => ({
    file: c.file,
    about: c.about,
    src: corpusSource(c.file),
    blocks: c.blocks,
    outline: c.outline || null,
    notes: c.notes || null
  }));

  const payload = JSON.stringify({ cases: cases, inline: INLINE_CASES, verbose: VERBOSE }, null, 2);

  // Plain JS inside a `.mts` file: type stripping only removes annotations, so the
  // runner needs no types of its own.
  const runner = `
import { MdParser } from './MdParser.mts';
import { MdBlockKind, MdInlineKind, MdCalloutKind, MdTaskState } from './MdTypes.mts';

const DATA = ${payload};

function reverse(map) {
  const out = {};
  for (const key of Object.keys(map)) {
    const value = map[key];
    if (typeof value === 'number') {
      out[value] = key;
    }
  }
  return out;
}

const KIND = reverse(MdBlockKind);
const INLINE_KIND = reverse(MdInlineKind);
const CALLOUT = reverse(MdCalloutKind);
const TASK = { '-1': 'None', '0': 'Todo', '1': 'Done' };

let checks = 0;
let fails = 0;

function eq(where, actual, expected) {
  checks++;
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a !== e) {
    fails++;
    console.log('  FAIL ' + where + '\\n        expected ' + e + '\\n        actual   ' + a);
  }
}

function checkBlock(where, exp, act) {
  if (exp.kind !== undefined) eq(where + '.kind', KIND[act.kind], exp.kind);
  if (exp.plain !== undefined) eq(where + '.plain', act.plain, exp.plain);
  if (exp.level !== undefined) eq(where + '.level', act.level, exp.level);
  if (exp.anchor !== undefined) eq(where + '.anchor', act.anchor === undefined ? '' : act.anchor, exp.anchor);
  if (exp.lang !== undefined) eq(where + '.lang', act.lang, exp.lang);
  if (exp.code !== undefined) eq(where + '.code', act.code, exp.code);
  if (exp.hl !== undefined) eq(where + '.hlLines', act.hlLines === undefined ? [] : act.hlLines, exp.hl);
  if (exp.aligns !== undefined) eq(where + '.aligns', act.aligns, exp.aligns);
  if (exp.rows !== undefined) eq(where + '.rows', act.rows.length, exp.rows);
  if (exp.cols !== undefined) {
    const cols = act.rows.length > 0 && act.rows[0].raw ? act.rows[0].raw.length : 0;
    eq(where + '.cols', cols, exp.cols);
  }
  if (exp.indent !== undefined) eq(where + '.indent', act.indent, exp.indent);
  if (exp.ordered !== undefined) eq(where + '.ordered', act.ordered, exp.ordered);
  if (exp.seq !== undefined) eq(where + '.seq', act.seq, exp.seq);
  if (exp.marker !== undefined) eq(where + '.marker', act.marker, exp.marker);
  if (exp.task !== undefined) eq(where + '.task', TASK['' + act.task], exp.task);
  if (exp.quoteDepth !== undefined) eq(where + '.quoteDepth', act.quoteDepth, exp.quoteDepth);
  if (exp.callout !== undefined) eq(where + '.callout', CALLOUT[act.callout], exp.callout);
  if (exp.srcLine !== undefined) eq(where + '.srcLine', act.srcLine, exp.srcLine);
  if (exp.inlines !== undefined) {
    eq(where + '.inlines',
      act.inlines.map((n) => ({ kind: INLINE_KIND[n.kind], text: n.text })),
      exp.inlines);
  }
}

function dumpBlock(act) {
  const kind = KIND[act.kind];
  let line = '      ' + kind;
  if (kind === 'Heading') line += ' h' + act.level;
  if (kind === 'ListItem') line += ' indent=' + act.indent + (act.ordered ? ' seq=' + act.seq : '');
  if (act.quoteDepth > 0) line += ' q=' + act.quoteDepth;
  line += ' | ' + JSON.stringify(act.plain.length > 60 ? act.plain.slice(0, 60) + '…' : act.plain);
  return line;
}

// --- block cases -----------------------------------------------------------

console.log('== corpus (' + DATA.cases.length + ' files) ==');
for (const c of DATA.cases) {
  let res;
  try {
    res = MdParser.parse(c.src);
  } catch (e) {
    fails++;
    console.log('  FAIL ' + c.file + ' threw: ' + (e && e.message ? e.message : String(e)));
    continue;
  }
  const blocks = res.blocks;
  const before = fails;
  eq(c.file + ' blockCount', blocks.length, c.blocks.length);
  const n = Math.min(blocks.length, c.blocks.length);
  for (let i = 0; i < n; i++) {
    checkBlock(c.file + '#' + i, c.blocks[i], blocks[i]);
  }
  if (c.outline !== null) {
    eq(c.file + ' outline.length', res.outline.length, c.outline.length);
    for (let i = 0; i < Math.min(res.outline.length, c.outline.length); i++) {
      const exp = c.outline[i];
      const act = res.outline[i];
      if (exp.level !== undefined) eq(c.file + ' outline#' + i + '.level', act.level, exp.level);
      if (exp.text !== undefined) eq(c.file + ' outline#' + i + '.text', act.text, exp.text);
      if (exp.blockIndex !== undefined) eq(c.file + ' outline#' + i + '.blockIndex', act.blockIndex, exp.blockIndex);
      if (exp.seq !== undefined) eq(c.file + ' outline#' + i + '.seq', act.seq, exp.seq);
      if (exp.anchor !== undefined) eq(c.file + ' outline#' + i + '.anchor', act.anchor, exp.anchor);
    }
  }
  if (c.notes !== null) {
    eq(c.file + ' notes.length', res.notes.length, c.notes.length);
    for (let i = 0; i < Math.min(res.notes.length, c.notes.length); i++) {
      const exp = c.notes[i];
      const act = res.notes[i];
      if (exp.no !== undefined) eq(c.file + ' note#' + i + '.no', act.no, exp.no);
      if (exp.label !== undefined) eq(c.file + ' note#' + i + '.label', act.label, exp.label);
      if (exp.text !== undefined) eq(c.file + ' note#' + i + '.text', act.text, exp.text);
      if (exp.blockIndex !== undefined) eq(c.file + ' note#' + i + '.blockIndex', act.blockIndex, exp.blockIndex);
    }
  }

  // 不变量：srcLine 单调不减；srcRangeOf 必须给出非空区间。
  for (let i = 1; i < blocks.length; i++) {
    checks++;
    if (blocks[i].srcLine < blocks[i - 1].srcLine) {
      fails++;
      console.log('  FAIL ' + c.file + ' srcLine regressed at #' + i + ' (' +
        blocks[i - 1].srcLine + ' -> ' + blocks[i].srcLine + ')');
    }
  }
  for (let i = 0; i < blocks.length; i++) {
    const range = MdParser.srcRangeOf(blocks, i);
    checks++;
    if (!(range.end > range.start) || range.start !== blocks[i].srcLine) {
      fails++;
      console.log('  FAIL ' + c.file + ' srcRangeOf(' + i + ') = ' +
        JSON.stringify(range) + ' for srcLine ' + blocks[i].srcLine);
    }
  }

  if (DATA.verbose) {
    console.log('  ' + c.file + ' — ' + c.about);
    for (const b of blocks) console.log(dumpBlock(b));
  } else {
    console.log('  ' + (fails === before ? 'ok  ' : 'FAIL') + ' ' + c.file);
  }
}

// --- inline cases ----------------------------------------------------------

function normInline(x) {
  return {
    kind: x.kind === undefined ? 'Plain' : x.kind,
    text: x.text === undefined ? '' : x.text,
    bold: x.bold === undefined ? false : x.bold,
    italic: x.italic === undefined ? false : x.italic,
    strike: x.strike === undefined ? false : x.strike,
    code: x.code === undefined ? false : x.code,
    href: x.href === undefined ? '' : x.href,
    num: x.num === undefined ? 0 : x.num
  };
}

console.log('== inline (' + DATA.inline.length + ' cases) ==');
for (const c of DATA.inline) {
  const before = fails;
  const got = MdParser.inlineOf(c.text).map((n) => normInline({
    kind: INLINE_KIND[n.kind],
    text: n.text,
    bold: n.bold,
    italic: n.italic,
    strike: n.strike,
    code: n.code,
    href: n.href,
    num: n.num
  }));
  const want = c.out.map(normInline);
  eq('inline ' + JSON.stringify(c.text) + ' nodeCount', got.length, want.length);
  for (let i = 0; i < Math.min(got.length, want.length); i++) {
    eq('inline ' + JSON.stringify(c.text) + '#' + i, got[i], want[i]);
  }
  if (fails === before) {
    console.log('  ok   ' + JSON.stringify(c.text) + '  (' + c.about + ')');
  } else {
    console.log('  FAIL ' + JSON.stringify(c.text) + '  (' + c.about + ')');
  }
}

// --- plainOf round trip ----------------------------------------------------

console.log('== plainOf ==');
{
  const samples = ['**粗**与*斜*', '\\\\*转义\\\\*', '\`代码\`', '[链](u)', '纯文本'];
  for (const s of samples) {
    const inl = MdParser.inlineOf(s);
    const plain = MdParser.plainOf(inl);
    checks++;
    const noMarkers = plain.indexOf('**') < 0 && plain.indexOf('\`') < 0 && plain.indexOf('](') < 0;
    if (!noMarkers) {
      fails++;
      console.log('  FAIL plainOf(' + JSON.stringify(s) + ') still carries markers: ' + JSON.stringify(plain));
    }
  }
  console.log('  ok   ' + samples.length + ' samples');
}

// --- garbage / robustness --------------------------------------------------

console.log('== robustness ==');
{
  let seed = 20261023;
  const next = () => {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff;
    return seed;
  };
  const pool = '#-*_~=<>[]()!|\`\\\\:.x 中文\\n';
  let bad = 0;
  const docs = [];
  for (let d = 0; d < 300; d++) {
    let s = '';
    const len = 1 + (next() % 120);
    for (let k = 0; k < len; k++) {
      s += pool.charAt(next() % pool.length);
    }
    docs.push(s);
  }
  const odd = ['', '\\n', '\\n\\n\\n', '---', '---\\n---', '\`\`\`', '~~~\\n~~~', '> ', '> > > ',
    '| | |', '$$', '[^', '![](', '#'.repeat(80), '-'.repeat(80), '\\u0000', '\\uFEFF# t'];
  for (const s of odd) docs.push(s);
  for (const s of docs) {
    try {
      const r = MdParser.parse(s);
      if (r === null || r.blocks === null) {
        bad++;
      }
    } catch (e) {
      bad++;
      console.log('  FAIL threw on ' + JSON.stringify(s) + ': ' + (e && e.message ? e.message : String(e)));
    }
  }
  checks++;
  if (bad > 0) {
    fails += bad;
  } else {
    console.log('  ok   ' + docs.length + ' malformed documents parsed without throwing');
  }
}

// --- normalize -------------------------------------------------------------

console.log('== normalize ==');
{
  const raw = '\\uFEFFa\\r\\nb\\rc\\td';
  eq('normalize', MdParser.normalize(raw), 'a\\nb\\nc    d');
  const crlf = MdParser.parse('# t\\r\\n\\r\\npara\\r\\n');
  eq('parse after CRLF heading', crlf.blocks.length, 2);
  eq('parse after CRLF plain', crlf.blocks[1].plain, 'para');
  const tabbed = MdParser.parse('- \\titem\\n  \\tcont');
  eq('tab list plain', tabbed.blocks[0].plain, 'item cont');
}

// --- srcRangeOf bounds -----------------------------------------------------

console.log('== srcRangeOf ==');
{
  const r = MdParser.parse('a\\n\\nb\\n\\nc');
  eq('srcRangeOf(-1)', MdParser.srcRangeOf(r.blocks, -1), { start: 0, end: 0 });
  eq('srcRangeOf(99)', MdParser.srcRangeOf(r.blocks, 99), { start: 0, end: 0 });
  eq('srcRangeOf(0)', MdParser.srcRangeOf(r.blocks, 0), { start: 0, end: 2 });
  eq('srcRangeOf(last)', MdParser.srcRangeOf(r.blocks, 2), { start: 4, end: 5 });
}

// --- performance -----------------------------------------------------------

console.log('== performance ==');
{
  const chunk = DATA.cases.map((c) => c.src).join('\\n');
  let doc = '';
  while (doc.length < 100000) {
    doc += chunk;
  }
  const t0 = Date.now();
  const res = MdParser.parse(doc);
  const ms = Date.now() - t0;
  console.log('  ' + doc.length + ' chars / ' + res.blocks.length + ' blocks: ' +
    ms + ' ms (target < 150 ms)');
  checks++;
  if (ms > 150) {
    console.log('  WARN over target — 复查 parseRegion / inlineScan 的热点');
  }
}

console.log('');
console.log(fails === 0
  ? 'PASS  ' + checks + ' checks'
  : 'FAILED  ' + fails + ' of ' + checks + ' checks');
process.exit(fails === 0 ? 0 : 1);
`;

  const runnerPath = path.join(TMP, 'runner.mts');
  fs.writeFileSync(runnerPath, runner, 'utf8');
  return runnerPath;
}

function main() {
  buildTmpModules();
  const runner = buildRunner();
  const proc = spawnSync(process.execPath, ['--experimental-transform-types', '--no-warnings', runner], {
    stdio: 'inherit',
    timeout: 180000
  });
  if (proc.error) {
    if (proc.error.code === 'ETIMEDOUT' || proc.signal) {
      console.error('\nFAILED: runner timed out — the parser likely failed to advance a cursor.');
      process.exit(2);
    }
    console.error('FAILED to spawn node: ' + proc.error.message);
    process.exit(2);
  }
  if (proc.status !== 0) {
    process.exit(proc.status === null ? 2 : proc.status);
  }
}

main();
