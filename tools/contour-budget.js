#!/usr/bin/env node
/**
 * 等高线背景的亮度预算验算。
 *
 * `common/ContourTheme.ets` 里的配色表带着一条可读性预算：普通线与计曲线相对
 * 底色的**感知亮度差**上限。这条预算不能只写在注释里——注释不会失败，而配色
 * 改一位十六进制就会悄悄越界。这个脚本把表照抄一份，按线上真实的合成公式
 * （`base + (line - base) * alpha`）算出每一条的实测落差，越界就非零退出。
 *
 * ## 为什么量亮度差而不是对比度比
 *
 * 对比度比（WCAG 那种 `(L1+0.05)/(L2+0.05)`）是为**成片的文字**定的。压在背景
 * 上的是一条 1.2 vp 的细线，它扎眼与否取决于与底色差多少个**灰阶**，而不是
 * 比值——在深色底上，`#1A1C1E` 与 `#222528` 的比值接近 1，可它们看起来几乎
 * 同色；而一条亮度差 30 级的线立刻就浮起来。
 *
 * 判据因此是：`|L(合成后) − L(底色)|`，其中 `L = 0.299R + 0.587G + 0.114B`。
 *
 * ## 三条约束
 *
 * 1. **普通线 ΔL 上限**（浅 16 / 深 14）：细线不能自成一条线，只该让底色有纹理。
 * 2. **计曲线 ΔL 上限**（浅 28 / 深 26）：它加粗是为读层级，但同样不能糊住小字。
 * 3. **计曲线必须比普通线强**：深色主题里这条最容易被写反——线取更深的颜色，
 *    在近黑底上反而更弱，加粗也救不回来。这里用比值 `≥ 1.6` 卡住方向。
 *
 * 跑法：`node tools/contour-budget.js`
 */

'use strict';

/** 与 `common/ContourTheme.ets` 的 `ContourThemes.all` 一一对应。改那边就要改这里。 */
const THEMES = [
  {
    label: '黄山',
    light: { base: ['#F0EDE8', '#E8E4DD', '#E0DBD3'], line: '#8A9BA8', index: '#6B7D8A', lineAlpha: 0.17, indexAlpha: 0.22 },
    dark: { base: ['#1A1C1E', '#222528', '#2A2D30'], line: '#5F7180', index: '#8FA3B2', lineAlpha: 0.16, indexAlpha: 0.18 }
  },
  {
    label: '龙脊',
    light: { base: ['#EDF0E8', '#E4E8DD', '#DBE0D3'], line: '#8A9E8A', index: '#6B806B', lineAlpha: 0.17, indexAlpha: 0.22 },
    dark: { base: ['#1A1E1A', '#222622', '#2A2E2A'], line: '#5F725F', index: '#8FA68F', lineAlpha: 0.17, indexAlpha: 0.19 }
  },
  {
    label: '长白',
    light: { base: ['#E8EBF0', '#DDE2E8', '#D3D9E0'], line: '#8090A8', index: '#607080', lineAlpha: 0.16, indexAlpha: 0.21 },
    dark: { base: ['#181A1E', '#202428', '#282C30'], line: '#5A6B80', index: '#8A9DB2', lineAlpha: 0.17, indexAlpha: 0.19 }
  },
  {
    label: '沙海',
    light: { base: ['#F0EBE0', '#E8E2D6', '#E0D9CC'], line: '#A89880', index: '#8A7A60', lineAlpha: 0.18, indexAlpha: 0.23 },
    dark: { base: ['#1E1C18', '#262420', '#2E2C28'], line: '#7A6A54', index: '#A89880', lineAlpha: 0.16, indexAlpha: 0.19 }
  },
  {
    label: '呼伦',
    light: { base: ['#E8F0F0', '#DDE8E8', '#D3E0E0'], line: '#809EA0', index: '#608080', lineAlpha: 0.17, indexAlpha: 0.22 },
    dark: { base: ['#181E1E', '#202626', '#282E2E'], line: '#54767A', index: '#87A9AB', lineAlpha: 0.16, indexAlpha: 0.18 }
  }
];

const BUDGET = {
  light: { line: 16, index: 28 },
  dark: { line: 14, index: 26 }
};
/** 计曲线相对普通线的最小强度倍数。低于它就是「层次没了」，不是「低调」。 */
const MIN_INDEX_RATIO = 1.6;

function rgb(hex) {
  return [1, 3, 5].map((i) => parseInt(hex.substring(i, i + 2), 16));
}

function lum(c) {
  return 0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2];
}

/** 在线性空间中合成的结果亮度；alpha=1 时就是线色本身。 */
function compositeLum(baseHex, lineHex, alpha) {
  const b = rgb(baseHex);
  const l = rgb(lineHex);
  const mixed = [0, 1, 2].map((i) => b[i] + (l[i] - b[i]) * alpha);
  return lum(mixed);
}

let failures = 0;
const rows = [];

for (const theme of THEMES) {
  for (const mode of ['light', 'dark']) {
    const spec = theme[mode];
    const budget = BUDGET[mode];
    let lineMin = Infinity, lineMax = -Infinity;
    let idxMin = Infinity, idxMax = -Infinity;
    for (const base of spec.base) {
      const dl = Math.abs(compositeLum(base, spec.line, spec.lineAlpha) - lum(rgb(base)));
      const di = Math.abs(compositeLum(base, spec.index, spec.indexAlpha) - lum(rgb(base)));
      lineMin = Math.min(lineMin, dl); lineMax = Math.max(lineMax, dl);
      idxMin = Math.min(idxMin, di); idxMax = Math.max(idxMax, di);
    }
    const ratio = idxMax / lineMax;
    const lineOk = lineMax <= budget.line;
    const idxOk = idxMax <= budget.index;
    const ratioOk = ratio >= MIN_INDEX_RATIO;
    rows.push({
      label: theme.label, mode,
      lineMin, lineMax, idxMin, idxMax, ratio,
      lineOk, idxOk, ratioOk
    });
    if (!lineOk || !idxOk || !ratioOk) { failures++; }
  }
}

console.log('地点   模式   普通线 ΔL      计曲线 ΔL      强度比   判定');
for (const r of rows) {
  const bad = [];
  if (!r.lineOk) { bad.push('普通线超预算'); }
  if (!r.idxOk) { bad.push('计曲线超预算'); }
  if (!r.ratioOk) { bad.push('计曲线不够强'); }
  console.log(
    r.label.padEnd(6),
    r.mode.padEnd(6),
    `${r.lineMin.toFixed(1)}..${r.lineMax.toFixed(1)}`.padEnd(14),
    `${r.idxMin.toFixed(1)}..${r.idxMax.toFixed(1)}`.padEnd(14),
    r.ratio.toFixed(2).padStart(5),
    '  ',
    bad.length === 0 ? 'ok' : bad.join(' / ')
  );
}

console.log(`\n预算：普通线 ≤${BUDGET.light.line}(浅)/${BUDGET.dark.line}(深)，` +
  `计曲线 ≤${BUDGET.light.index}(浅)/${BUDGET.dark.index}(深)，强度比 ≥${MIN_INDEX_RATIO}`);
if (failures > 0) {
  console.error(`\n${failures} 项越界`);
  process.exit(1);
}
console.log('全部在预算内');
