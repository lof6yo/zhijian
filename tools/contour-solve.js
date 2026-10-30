#!/usr/bin/env node
/**
 * 等高线配色的参数求解器。
 *
 * `contour-budget.js` 判「越界没有」，这个脚本负责**找出该用多少**。
 *
 * ## 为什么需要求解而不是手调
 *
 * 亮度差是 `|L(base + (line − base)·α) − L(base)|`，对 α 是线性的，但对
 * **颜色**不是：同样的 α 换一个底色就变一个值，五个地点 × 两种模式 = 10 组，
 * 每组还有普通线与计曲线两个目标。手调一轮要改十个数字，改完还得再跑一次
 * 验算；而目标本身是「贴着上限但不超过」，靠手感必然要么浪费动态范围、要么
 * 越界。
 *
 * 做法：**固定颜色，二分 α**。颜色承担「这套设计语言的色相」，α 只承担强度。
 * 反过来说，如果某个颜色在 α=1 时都够不到目标强度，那说明色相本身选错了——
 * 脚本会把这种情形单独报出来，而不是给出一个 α>1 的假答案。
 *
 * 跑法：`node tools/contour-solve.js`
 */

'use strict';

/** 目标亮度差：取预算的 92%，给设备上的实际渲染留一点余量。 */
const TARGET = {
  light: { line: 15.0, index: 26.0 },
  dark: { line: 13.0, index: 24.0 }
};

/** 与 `common/ContourTheme.ets` 的 `ContourThemes.all` 一一对应。 */
const THEMES = [
  {
    label: '黄山',
    light: { base: ['#F0EDE8', '#E8E4DD', '#E0DBD3'], line: '#8A9BA8', index: '#6B7D8A' },
    dark: { base: ['#1A1C1E', '#222528', '#2A2D30'], line: '#5F7180', index: '#8FA3B2' }
  },
  {
    label: '龙脊',
    light: { base: ['#EDF0E8', '#E4E8DD', '#DBE0D3'], line: '#8A9E8A', index: '#6B806B' },
    dark: { base: ['#1A1E1A', '#222622', '#2A2E2A'], line: '#5F725F', index: '#8FA68F' }
  },
  {
    label: '长白',
    light: { base: ['#E8EBF0', '#DDE2E8', '#D3D9E0'], line: '#8090A8', index: '#607080' },
    dark: { base: ['#181A1E', '#202428', '#282C30'], line: '#5A6B80', index: '#8A9DB2' }
  },
  {
    label: '沙海',
    light: { base: ['#F0EBE0', '#E8E2D6', '#E0D9CC'], line: '#A89880', index: '#8A7A60' },
    dark: { base: ['#1E1C18', '#262420', '#2E2C28'], line: '#7A6A54', index: '#A89880' }
  },
  {
    label: '呼伦',
    light: { base: ['#E8F0F0', '#DDE8E8', '#D3E0E0'], line: '#809EA0', index: '#608080' },
    dark: { base: ['#181E1E', '#202626', '#282E2E'], line: '#54767A', index: '#87A9AB' }
  }
];

function rgb(hex) {
  return [1, 3, 5].map((i) => parseInt(hex.substring(i, i + 2), 16));
}

function lum(c) {
  return 0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2];
}

function deltaAt(baseHex, lineHex, alpha) {
  const b = rgb(baseHex);
  const l = rgb(lineHex);
  const mixed = [0, 1, 2].map((i) => b[i] + (l[i] - b[i]) * alpha);
  return Math.abs(lum(mixed) - lum(b));
}

/**
 * 二分出「最大 ΔL 恰好等于 target」的 α。
 *
 * 判据用**三档底色里最大的那个 ΔL**，不是平均：最扎眼的那一档决定了这组配色
 * 会不会破坏可读性，平均值会把它稀释掉。
 *
 * α 与 ΔL 在 [0,1] 上是单调的（合成走的是直线），所以二分收敛。若 α=1 仍达不到
 * 目标，返回 null——那是色相的问题，不该由 α 硬凑。
 */
function solveAlpha(bases, lineHex, target) {
  const maxAt = (a) => Math.max(...bases.map((b) => deltaAt(b, lineHex, a)));
  if (maxAt(1) < target) { return null; }
  let lo = 0, hi = 1;
  for (let i = 0; i < 24; i++) {
    const mid = (lo + hi) / 2;
    if (maxAt(mid) < target) { lo = mid; } else { hi = mid; }
  }
  return hi;
}

const out = [];
let unsolvable = 0;

for (const theme of THEMES) {
  for (const mode of ['light', 'dark']) {
    const spec = theme[mode];
    const target = TARGET[mode];
    const lineA = solveAlpha(spec.base, spec.line, target.line);
    const indexA = solveAlpha(spec.base, spec.index, target.index);
    if (lineA === null || indexA === null) {
      unsolvable++;
      console.log(`!! ${theme.label} ${mode}: 色相在 α=1 也达不到目标强度`);
      continue;
    }
    const lineD = Math.max(...spec.base.map((b) => deltaAt(b, spec.line, lineA)));
    const indexD = Math.max(...spec.base.map((b) => deltaAt(b, spec.index, indexA)));
    out.push({
      label: theme.label, mode,
      line: spec.line, index: spec.index,
      lineA, indexA, lineD, indexD,
      ratio: indexD / lineD
    });
  }
}

console.log('地点   模式   普通线         α      计曲线         α      强度比');
for (const r of out) {
  console.log(
    r.label.padEnd(6), r.mode.padEnd(6),
    `${r.line} ΔL=${r.lineD.toFixed(1)}`.padEnd(22), r.lineA.toFixed(2).padEnd(6),
    `${r.index} ΔL=${r.indexD.toFixed(1)}`.padEnd(22), r.indexA.toFixed(2).padEnd(6),
    r.ratio.toFixed(2)
  );
}

// 直接吐出可以直接粘进 `ContourTheme.ets` 的构造行，避免手抄出错。
console.log('\n// ---- ContourInk(...) 行，可直接替换');
for (const r of out) {
  const a = (x) => x.toFixed(2);
  console.log(`  ${r.label} ${r.mode}: new ContourInk('${r.line}', '${r.index}', ${a(r.lineA)}, ${a(r.indexA)})`);
}

if (unsolvable > 0) { process.exit(1); }
