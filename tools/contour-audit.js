/**
 * 背景可读性审计：在**纯背景**区域量等高线的 ΔL，并给出最坏像素的 RGB。
 *
 * 用法：node tools/contour-audit.js <shot.png> <x0> <x1> <y0> <y1> [标签]
 *
 * 为什么不用 `contour-measure.js` 的 85 分位底色：那是按「窗口里绝大多数像素是
 * 底色」估的，只在竖直方向没有渐变时成立。这里改成**按行取 95 分位**——等高线
 * 是细线，同一行上它只能占少数像素，而底色在水平方向是缓变的（160° 渐变）。
 *
 * 输出的 P99 / max 是「一条线最坏能压多深」；同时打印最深那个像素的 RGB，
 * 用来判断它到底是**一条计曲线**，还是两条线叠在一起（RGB 比单线合成更深）。
 */
const fs = require('fs');
const zlib = require('zlib');

function decode(file) {
  const b = fs.readFileSync(file);
  let p = 8, w = 0, h = 0, ct = 0;
  const idat = [];
  while (p < b.length) {
    const len = b.readUInt32BE(p);
    const type = b.toString('ascii', p + 4, p + 8);
    const data = b.subarray(p + 8, p + 8 + len);
    if (type === 'IHDR') {
      w = data.readUInt32BE(0);
      h = data.readUInt32BE(4);
      ct = data[9];
    } else if (type === 'IDAT') {
      idat.push(data);
    } else if (type === 'IEND') {
      break;
    }
    p += 12 + len;
  }
  const ch = ct === 6 ? 4 : 3;
  const raw = zlib.inflateSync(Buffer.concat(idat));
  const stride = w * ch;
  const out = Buffer.alloc(w * h * ch);
  let prev = Buffer.alloc(stride);
  for (let y = 0; y < h; y++) {
    const f = raw[y * (stride + 1)];
    const line = raw.subarray(y * (stride + 1) + 1, y * (stride + 1) + 1 + stride);
    const cur = Buffer.alloc(stride);
    for (let i = 0; i < stride; i++) {
      const a = i >= ch ? cur[i - ch] : 0;
      const bb = prev[i];
      const c = i >= ch ? prev[i - ch] : 0;
      let v = line[i];
      switch (f) {
        case 0: break;
        case 1: v += a; break;
        case 2: v += bb; break;
        case 3: v += (a + bb) >> 1; break;
        case 4: {
          const pr = a + bb - c;
          const pa = Math.abs(pr - a), pb = Math.abs(pr - bb), pc = Math.abs(pr - c);
          v += (pa <= pb && pa <= pc) ? a : (pb <= pc ? bb : c);
          break;
        }
      }
      cur[i] = v & 0xff;
    }
    cur.copy(out, y * stride);
    prev = cur;
  }
  return { w, h, ch, data: out };
}

const [, , file, x0s, x1s, y0s, y1s, label] = process.argv;
const im = decode(file);
const x0 = +x0s, x1 = +x1s, y0 = +y0s, y1 = +y1s;

const lum = (x, y) => {
  const i = (y * im.w + x) * im.ch;
  return 0.299 * im.data[i] + 0.587 * im.data[i + 1] + 0.114 * im.data[i + 2];
};
const rgb = (x, y) => {
  const i = (y * im.w + x) * im.ch;
  return `${im.data[i]},${im.data[i + 1]},${im.data[i + 2]}`;
};

const res = [];
let worst = { d: -1, x: 0, y: 0 };
for (let y = y0; y <= y1; y++) {
  const row = [];
  for (let x = x0; x <= x1; x++) {
    row.push(lum(x, y));
  }
  const sorted = row.slice().sort((a, b) => a - b);
  const base = sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * 0.95))];
  for (let x = x0; x <= x1; x++) {
    const d = base - lum(x, y);
    if (d > 0.8) {
      res.push(d);
      if (d > worst.d) {
        worst = { d, x, y };
      }
    }
  }
}

res.sort((a, b) => a - b);
const pct = (p) => res[Math.min(res.length - 1, Math.floor(res.length * p))];
const area = (x1 - x0 + 1) * (y1 - y0 + 1);
console.log(
  `${label || ''} 线像素 ${(100 * res.length / area).toFixed(1)}%` +
  `  中位 ${pct(0.5).toFixed(1)}  P90 ${pct(0.9).toFixed(1)}` +
  `  P99 ${pct(0.99).toFixed(1)}  max ${worst.d.toFixed(1)} @(${worst.x},${worst.y}) rgb ${rgb(worst.x, worst.y)}`
);
