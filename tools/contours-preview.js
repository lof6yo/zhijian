#!/usr/bin/env node
/**
 * contours-preview.js — 把 `rawfile/contours/*.txt` 画成一张 PNG
 * =============================================================
 *
 * `gen-contours.js` 的自检眼睛。光看「层数 / 点数 / KB」判断不了地形对不对：
 * 一份 8 层 4609 点的数据可能是舒展的同心弧，也可能是一堆细碎的火柴盒，
 * 两者的统计量一模一样。背景是全应用最容易「看起来还行、其实一团糊」的地方，
 * 所以每改一次参数都该先画出来看一眼。
 *
 * 输出 `tools/.tmp/contours-preview.png`（`/tools/.tmp` 不入库）：五个地点横排，
 * 每块按画布比例缩放（画布是屏幕比例，不是正方形），深色底浅色线——与 app 深色
 * 主题的明暗关系一致，好判断线的可读性。
 *
 * 跑法：`node tools/contours-preview.js`
 */

'use strict';

const fs = require('fs');
const path = require('path');
const zlib = require('zlib');

const ROOT = path.resolve(__dirname, '..');
const IN_DIR = path.join(ROOT, 'entry/src/main/resources/rawfile/contours');
const OUT = path.join(ROOT, 'tools/.tmp/contours-preview.png');

const PLACES = ['huangshan', 'longji', 'changbai', 'taklamakan', 'hulunbuir'];
const PANEL_H = 420;
const GAP = 8;
const BG = [22, 24, 28];
const INK = [150, 178, 200];
const INK_IDX = [214, 232, 245];

// ---------------------------------------------------------------- 格式解析

/**
 * 读 `{key}.txt`。格式见 `gen-contours.js` 头部注释：首行是头部，`L` 开层，
 * 其余每行一条路径（首点绝对、其后全是增量）。
 *
 * 这个解析器就是 ArkTS 侧 `ContourGeometry.parse()` 的逐行对应物——两边必须
 * 认同一份格式，否则这里画得对不代表设备上画得对。
 */
function parse(text) {
  const lines = text.split('\n');
  const head = lines[0].trim().split(' ');
  const levels = [];
  let cur = null;
  for (let i = 1; i < lines.length; i++) {
    const line = lines[i];
    if (!line) { continue; }
    if (line[0] === 'L') {
      const parts = line.split(' ');
      cur = { h: Number(parts[1]), idx: parts[2] === '1', paths: [] };
      levels.push(cur);
      continue;
    }
    if (!cur) { continue; }
    const nums = line.split(' ').map(Number);
    const p = [nums[0], nums[1]];
    let x = nums[0], y = nums[1];
    for (let k = 2; k < nums.length; k += 2) {
      x += nums[k];
      y += nums[k + 1];
      p.push(x, y);
    }
    cur.paths.push(p);
  }
  return {
    key: head[0],
    interval: Number(head[1]),
    min: Number(head[2]),
    max: Number(head[3]),
    w: Number(head[4]),
    h: Number(head[5]),
    levels: levels
  };
}

// ---------------------------------------------------------------- PNG 编码

function crc32(buf) {
  let c, crc = 0xffffffff;
  for (let n = 0; n < buf.length; n++) {
    c = (crc ^ buf[n]) & 0xff;
    for (let k = 0; k < 8; k++) { c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; }
    crc = (crc >>> 8) ^ c;
  }
  return (crc ^ 0xffffffff) >>> 0;
}

function chunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length);
  const body = Buffer.concat([Buffer.from(type, 'ascii'), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(body));
  return Buffer.concat([len, body, crc]);
}

function encodePng(width, height, rgb) {
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8; ihdr[9] = 2; ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;
  const stride = width * 3;
  const raw = Buffer.alloc((stride + 1) * height);
  for (let y = 0; y < height; y++) {
    raw[y * (stride + 1)] = 0;
    rgb.copy(raw, y * (stride + 1) + 1, y * stride, y * stride + stride);
  }
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr),
    chunk('IDAT', zlib.deflateSync(raw, { level: 9 })),
    chunk('IEND', Buffer.alloc(0))
  ]);
}

// ---------------------------------------------------------------- 画线

/** 1 px 宽的抗锯齿线段：按到线段的距离算覆盖率。 */
function stroke(W, H, px, x0, y0, x1, y1, color, alpha) {
  const minX = Math.max(0, Math.floor(Math.min(x0, x1) - 1));
  const maxX = Math.min(W - 1, Math.ceil(Math.max(x0, x1) + 1));
  const minY = Math.max(0, Math.floor(Math.min(y0, y1) - 1));
  const maxY = Math.min(H - 1, Math.ceil(Math.max(y0, y1) + 1));
  const dx = x1 - x0, dy = y1 - y0;
  const len2 = dx * dx + dy * dy || 1e-9;
  for (let y = minY; y <= maxY; y++) {
    for (let x = minX; x <= maxX; x++) {
      let t = ((x - x0) * dx + (y - y0) * dy) / len2;
      t = t < 0 ? 0 : t > 1 ? 1 : t;
      const ddx = x - (x0 + dx * t), ddy = y - (y0 + dy * t);
      const cov = Math.max(0, 1 - Math.sqrt(ddx * ddx + ddy * ddy)) * alpha;
      if (cov <= 0) { continue; }
      const i = (y * W + x) * 3;
      px[i] = Math.round(px[i] + (color[0] - px[i]) * cov);
      px[i + 1] = Math.round(px[i + 1] + (color[1] - px[i + 1]) * cov);
      px[i + 2] = Math.round(px[i + 2] + (color[2] - px[i + 2]) * cov);
    }
  }
}

// ---------------------------------------------------------------- 主流程

const docs = PLACES.map((key) => {
  const file = path.join(IN_DIR, `${key}.txt`);
  return fs.existsSync(file) ? parse(fs.readFileSync(file, 'utf8')) : null;
}).filter((d) => d !== null);

// 所有地点同一缩放系数，这样横排比较的是「同一个屏幕大小」下的密度。
const scale = (PANEL_H - 1) / Math.max(...docs.map((d) => d.h));
const widths = docs.map((d) => Math.round(d.w * scale));
const W = widths.reduce((n, w) => n + w, 0) + GAP * (docs.length - 1);
const H = PANEL_H;
const px = Buffer.alloc(W * H * 3);
for (let i = 0; i < px.length; i += 3) { px[i] = BG[0]; px[i + 1] = BG[1]; px[i + 2] = BG[2]; }

let ox = 0;
const report = [];
docs.forEach((data, n) => {
  for (const level of data.levels) {
    const isIdx = level.idx === true;
    const color = isIdx ? INK_IDX : INK;
    const alpha = isIdx ? 0.85 : 0.45;
    for (const p of level.paths) {
      for (let i = 2; i < p.length; i += 2) {
        stroke(W, H, px,
          ox + p[i - 2] * scale, p[i - 1] * scale,
          ox + p[i] * scale, p[i + 1] * scale,
          color, alpha);
        // 计曲线加粗：同一段再描一次偏移 0.8 px 的副本
        if (isIdx) {
          stroke(W, H, px,
            ox + p[i - 2] * scale + 0.8, p[i - 1] * scale,
            ox + p[i] * scale + 0.8, p[i + 1] * scale,
            color, alpha * 0.85);
        }
      }
    }
  }
  ox += widths[n] + GAP;
  const paths = data.levels.reduce((k, l) => k + l.paths.length, 0);
  report.push(`  ${data.key.padEnd(12)} ${String(data.levels.length).padStart(2)} levels  ` +
    `${String(paths).padStart(4)} paths  interval ${String(data.interval).padStart(3)} m  ` +
    `${data.min}–${data.max} m`);
});

if (!fs.existsSync(path.dirname(OUT))) { fs.mkdirSync(path.dirname(OUT), { recursive: true }); }
fs.writeFileSync(OUT, encodePng(W, H, px));
console.log(report.join('\n'));
console.log(`\nwrote ${path.relative(ROOT, OUT)}  (${W}×${H})`);
