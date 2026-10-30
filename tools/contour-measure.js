/**
 * 从设备截图里量「等高线本身」的 ΔL，用来验收可读性预算。
 *
 * 用法：
 *   node tools/contour-measure.js <shot.png> column <x0> <x1> <y0> <y1>
 *   node tools/contour-measure.js <shot.png> band   <x0> <x1> <y0> <y1>
 *
 * 两种量法的区别是「底色怎么估」：
 *
 * - `column`：双列网格的列缝。那个竖条里除了等高线没有任何控件，所以沿**列**
 *   取 85 分位当底色——线只让像素变暗，85 分位基本落在无线的底色上，而底色
 *   的竖向渐变在这个窗口内变化很小。
 * - `band`：横向一条带（标题栏、页签栏）。同一行上从左到右没有控件时用 85 分位；
 *   有渐变就用中值窗口，见 `medianBand`。
 *
 * 为什么要 85 分位而不是中值：一条线能覆盖窗口里一半以上的像素（等高线很密），
 * 那时中值本身就是线，残差会被算成 0——测出来「很安全」，其实线条满屏。
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

function lumAt(im, x, y) {
  const i = (y * im.w + x) * im.ch;
  return 0.299 * im.data[i] + 0.587 * im.data[i + 1] + 0.114 * im.data[i + 2];
}

const pct = (arr, p) => arr[Math.min(arr.length - 1, Math.floor(arr.length * p))];

function report(label, residuals, area) {
  residuals.sort((a, b) => a - b);
  if (residuals.length === 0) {
    console.log(`${label}: 窗口内没有量到线像素（面积 ${area}）`);
    return;
  }
  console.log(
    `${label}: 线像素 ${residuals.length} (${(100 * residuals.length / area).toFixed(1)}%)` +
    `  中位 ${pct(residuals, 0.5).toFixed(1)}` +
    `  P90 ${pct(residuals, 0.9).toFixed(1)}` +
    `  P99 ${pct(residuals, 0.99).toFixed(1)}` +
    `  最大 ${residuals[residuals.length - 1].toFixed(1)}`
  );
}

const [, , file, mode, x0s, x1s, y0s, y1s] = process.argv;
const im = decode(file);
const x0 = +x0s, x1 = +x1s, y0 = +y0s, y1 = +y1s;
console.log(`图像 ${im.w}×${im.h} 窗口 x=${x0}..${x1} y=${y0}..${y1}`);

const res = [];
for (let y = y0; y <= y1; y++) {
  for (let x = x0; x <= x1; x++) {
    const win = [];
    if (mode === 'column') {
      for (let k = -60; k <= 60; k++) {
        const yy = y + k;
        if (yy >= 0 && yy < im.h) win.push(lumAt(im, x, yy));
      }
    } else {
      for (let k = -30; k <= 30; k++) {
        const xx = x + k;
        if (xx >= 0 && xx < im.w) win.push(lumAt(im, xx, y));
      }
    }
    win.sort((a, b) => a - b);
    const base = win[Math.floor(win.length * 0.85)];
    const d = base - lumAt(im, x, y);
    if (d > 0.8) res.push(d);
  }
}
report('测量', res, (x1 - x0 + 1) * (y1 - y0 + 1));
