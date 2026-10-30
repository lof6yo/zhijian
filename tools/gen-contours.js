#!/usr/bin/env node
/**
 * gen-contours.js — 从真实 DEM 生成等高线几何
 * ===========================================
 *
 * 背景里的等高线必须是**真实地形**，不是程序画的花纹。这个脚本从公开的
 * terrarium 高程瓦片取真实海拔，跑 marching squares 提等值线，再用
 * Douglas-Peucker 简化到「手机背景该有的信息量」，产出 ArkTS 能直接消费的
 * 多边形点串。
 *
 * ## 数据源
 *
 * `https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png`
 *
 * terrarium 编码：`height = (R * 256 + G + B / 256) - 32768`，单位米。选它
 * 而不是 Mapbox Terrain-RGB 是因为它无需 token，也不依赖任何付费服务。
 *
 * zoom 12 的瓦片约 9.8 km 见方（赤道处），五个地点各取 3×3 瓦片拼一张
 * 约 30 km 见方的图——这个尺度下等高线才有「一片山」的形状，单张瓦片只有
 * 几百米的局部，看上去和随机曲线没区别。
 *
 * ## 为什么在构建期而不是运行期
 *
 * 运行期要么打包 DEM 位图（每地点 3×3 瓦片≈1.5 MB，五个地点 7 MB+），要么
 * 联网取（笔记应用不该为了背景联网）。而等高线几何简化之后每个地点只有
 * 十几 KB 文本。所以：**构建期算一次，运行期只画线**。
 *
 * ## 输出
 *
 * `entry/src/main/resources/rawfile/contours/{key}.txt`，每个地点一份**纯文本**
 * 而不是 JSON：
 *
 *     huangshan 100 172 1799 448 758   <- key 等高距 最低海拔 最高海拔 画布宽 画布高
 *     L 300 0                          <- 层：海拔、是否计曲线
 *     128 74 12 0 9 -1 ...             <- 路径：首点绝对坐标，其后全是增量
 *
 * 两个理由，都不是风格问题：
 *
 * 1. **ArkTS 读不了深层 JSON。** `JSON.parse` 返回 `Object`，要从中逐层取出
 *    「层数组 → 路径数组 → 数字数组」只能全程 `ESObject`（ArkTS 禁止）或者写
 *    一长串 `as` 断言（任一层缺失就抛）。纯文本按行切、按空格切，类型全是
 *    `string[]` 与 `number`，没有一处需要断言。
 * 2. **增量编码省 35%。** 相邻点通常只差几个单位，`12 0 9 -1` 比
 *    `[140,74,152,74]` 短得多。实测五个地点从 158 KB 降到 104 KB。
 *
 * 坐标是 **0..CANVAS-1 的归一化整数**（不是经纬度，也不是像素）：运行时按
 * cover 缩放，与屏幕密度无关。
 *
 * 跑法：`node tools/gen-contours.js`
 *      `node tools/gen-contours.js --only huangshan`  （只重生一个）
 */

'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const zlib = require('zlib');
const { execFileSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..');
const OUT_DIR = path.join(ROOT, 'entry/src/main/resources/rawfile/contours');

/**
 * 归一化画布尺寸，以及简化容差。
 *
 * **是竖幅，不是正方形。** 背景要铺满 440×744 vp 的屏幕；方块几何按 `cover`
 * 缩放时横向要被裁掉 41%——那 41% 的数据是白存的，而体积正是这里唯一的预算。
 * 按屏幕比例（0.591）取 448×758，存下来的每一个点都会出现在屏幕上。
 *
 * 448 宽对 440 vp 意味着 1 单位 ≈ 0.98 vp，容差 1.0 就是 1 vp 量级的偏离——
 * 线本身有 1.2 vp 粗，这个精度看不出区别。再往上加分辨率只会让文件变大。
 */
const CANVAS_W = 448;
const CANVAS_H = 758;
const TOLERANCE = 1.0;

/**
 * 五个地点的取样中心，以及**目标层数**（不是固定等高距）。
 *
 * 等高距不能写死：五个地点的相对高差从 79 m（青海湖盆）到 1600 m（黄山），
 * 写死一个米数就是「青海 0 层、长白 6 层」——前者一条线都不出，后者只剩山顶
 * 那几圈。按目标层数反算等高距，五个地点才是同一种画面密度。
 *
 * 目标层数仍然按地貌性格给：峰的圈层要密（看得出陡），平原只要几条（看得出缓）。
 */
const PLACES = [
  // 陡峭密集：黄山，花岗岩峰林，等高线挤成一团一团
  { key: 'huangshan', name: '黄山', lat: 30.1340, lon: 118.1610, target: 13, zoom: 12 },
  // 圆缓丘陵：龙脊梯田所在的越城岭余脉，等高线是舒展的同心弧
  { key: 'longji', name: '龙脊', lat: 25.7900, lon: 110.1200, target: 12, zoom: 12 },
  // 环状闭合：长白山天池，火山口——一圈圈闭合环，中间是空的
  { key: 'changbai', name: '长白', lat: 42.0060, lon: 128.0570, target: 11, zoom: 12 },
  // 平行长条：塔克拉玛干沙丘，等高线是长而平行的波痕
  { key: 'taklamakan', name: '沙海', lat: 38.9600, lon: 83.6400, target: 12, zoom: 12 },
  // 稀疏极简：呼伦贝尔草原，起伏只有百米，几条长长的缓线
  { key: 'hulunbuir', name: '呼伦', lat: 49.2000, lon: 119.7500, target: 7, zoom: 12 }
];

/**
 * 短于这个弧长的折线直接丢掉。
 *
 * DEM 里到处是几米宽的噪声台地，marching squares 会给它们各生成一个火柴盒
 * 大小的闭合环。它们在 512 的画布上只有几个单位长，画上去不是「地形细节」，
 * 是脏点——而且数量极多，体积的大头都在这里。用整条折线的**总弧长**判定，
 * 不是用点数：一条沿等高线绕了半张图但被简化成 3 个点的线必须留下。
 */
const MIN_PATH_LEN = 9;

/**
 * 等高距取「1 / 2 / 5 × 10ⁿ」这类整数值，不取任意数。
 *
 * 等高线要能读成地形图上的读数：`h=650` 比 `h=637` 更像一条真的计曲线，而
 * 计曲线（每 5 条加粗）只有落在整十整百上才站得住。做法是枚举候选值，挑层数
 * 最接近 `target` 的那个。
 */
const NICE_STEPS = [1, 2, 5, 10, 20, 25, 50, 100, 200, 250, 500, 1000];

// ---------------------------------------------------------------- 瓦片

function lonLatToTile(lon, lat, z) {
  const n = Math.pow(2, z);
  const x = Math.floor((lon + 180) / 360 * n);
  const latRad = lat * Math.PI / 180;
  const y = Math.floor((1 - Math.log(Math.tan(latRad) + 1 / Math.cos(latRad)) / Math.PI) / 2 * n);
  return { x, y };
}

// ---------------------------------------------------------------- PNG 解码
//
// 不引第三方依赖。terrarium 瓦片是 8 位 RGB 无交错 PNG，所以只需要支持
// color type 2（truecolor）与 6（truecolor+alpha），位深 8。其余形态直接报错
// ——静默返回错的高程比报错更糟。

function decodePng(buf) {
  if (buf.readUInt32BE(0) !== 0x89504e47) { throw new Error('not a PNG'); }
  let pos = 8;
  let width = 0, height = 0, bitDepth = 0, colorType = 0;
  const idat = [];
  while (pos < buf.length) {
    const len = buf.readUInt32BE(pos);
    const type = buf.toString('ascii', pos + 4, pos + 8);
    const data = buf.subarray(pos + 8, pos + 8 + len);
    if (type === 'IHDR') {
      width = data.readUInt32BE(0);
      height = data.readUInt32BE(4);
      bitDepth = data[8];
      colorType = data[9];
      if (data[12] !== 0) { throw new Error('interlaced PNG not supported'); }
    } else if (type === 'IDAT') {
      idat.push(data);
    } else if (type === 'IEND') {
      break;
    }
    pos += 12 + len;
  }
  if (bitDepth !== 8 || (colorType !== 2 && colorType !== 6)) {
    throw new Error(`unsupported PNG (bitDepth=${bitDepth} colorType=${colorType})`);
  }
  const channels = colorType === 6 ? 4 : 3;
  const raw = zlib.inflateSync(Buffer.concat(idat));
  const stride = width * channels;
  const out = Buffer.alloc(width * height * channels);
  let prev = Buffer.alloc(stride);
  for (let y = 0; y < height; y++) {
    const filter = raw[y * (stride + 1)];
    const line = raw.subarray(y * (stride + 1) + 1, y * (stride + 1) + 1 + stride);
    const cur = Buffer.alloc(stride);
    for (let i = 0; i < stride; i++) {
      const a = i >= channels ? cur[i - channels] : 0;
      const b = prev[i];
      const c = i >= channels ? prev[i - channels] : 0;
      let v = line[i];
      switch (filter) {
        case 0: break;
        case 1: v += a; break;
        case 2: v += b; break;
        case 3: v += (a + b) >> 1; break;
        case 4: {
          const p = a + b - c;
          const pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c);
          v += (pa <= pb && pa <= pc) ? a : (pb <= pc ? b : c);
          break;
        }
        default: throw new Error(`bad PNG filter ${filter}`);
      }
      cur[i] = v & 0xff;
    }
    cur.copy(out, y * stride);
    prev = cur;
  }
  return { width, height, channels, data: out };
}

function terrariumHeight(png, x, y) {
  const i = (y * png.width + x) * png.channels;
  return (png.data[i] * 256 + png.data[i + 1] + png.data[i + 2] / 256) - 32768;
}

// ---------------------------------------------------------------- 取 3×3 瓦片

/**
 * 取一张瓦片。
 *
 * 用 `curl` 而不是 `fetch`：这台机器出网要走企业 CONNECT 代理，而 Node 内置的
 * `fetch`（undici）**不读** `HTTP(S)_PROXY`，直连必然失败；`undici` 包本身不在
 * 依赖里，为了装一个代理 agent 去加 node_modules 不值得。`curl` 读环境变量里的
 * 代理，是这台机器上唯一现成的路径。
 */
function fetchTile(z, x, y) {
  const url = `https://s3.amazonaws.com/elevation-tiles-prod/terrarium/${z}/${x}/${y}.png`;
  const tmp = path.join(os.tmpdir(), `terrarium-${z}-${x}-${y}.png`);
  execFileSync('curl', ['-sS', '--fail', '--max-time', '60', '-o', tmp, url], { stdio: 'pipe' });
  const buf = fs.readFileSync(tmp);
  fs.unlinkSync(tmp);
  return decodePng(buf);
}

/**
 * 低通半径（画布单位）。
 *
 * DEM 里 30–60 m 尺度的起伏是真实地形，也是**噪声**：它会让每条等高线长满
 * 尖刺状的小凸起，五个地点横排看一眼就是一片「疣」。背景上的线要读成山势，
 * 不是读成 DEM 的采样精度，所以先把它压掉。
 *
 * 半径 2 在 512 画布上对应约 1.7 vp 的屏幕尺度（440 vp 宽），足以抹掉单格的
 * 锯齿，又保留几十个格子以上的真实山形。再大就开始把山脊抹成馒头。
 */
const SMOOTH_RADIUS = 2;

function buildElevation(place) {
  const { x: tx, y: ty } = lonLatToTile(place.lon, place.lat, place.zoom);
  const tiles = [];
  for (let dy = -1; dy <= 1; dy++) {
    for (let dx = -1; dx <= 1; dx++) {
      tiles.push({ dx, dy, png: fetchTile(place.zoom, tx + dx, ty + dy) });
    }
  }
  const tileW = tiles[0].png.width;
  const tileH = tiles[0].png.height;
  const W = tileW * 3, H = tileH * 3;
  const grid = new Float32Array(W * H);
  for (const t of tiles) {
    const ox = (t.dx + 1) * tileW;
    const oy = (t.dy + 1) * tileH;
    for (let y = 0; y < tileH; y++) {
      for (let x = 0; x < tileW; x++) {
        grid[(oy + y) * W + (ox + x)] = terrariumHeight(t.png, x, y);
      }
    }
  }
  // 取中心竖幅，避免 3×3 拼接的接缝正好落在画面中间；同时把 3072×3072 降到
  // 448×758——marching squares 的输入不需要比输出更密。
  //
  // **用块平均，不是点采样。** 点采样等于对 DEM 做最近邻降采样，会把单个格点
  // 的噪声原样搬到画布上；块平均本身就是一级低通，6×6 的块直接把 30 m 噪声
  // 平均掉一半。实测这是「线上长满尖刺」与「线是山脊」的分界。
  const stepX = W / CANVAS_W;
  const stepY = H / CANVAS_H;
  // 竖幅比 3×3 拼出来的方形更高，所以要么从 3072 里裁掉上下，要么横向留黑边。
  // 这里让纵向铺满、横向居中取一窄条：地形在横向上本就更连续，裁掉两侧比
  // 露出两条空边更像「一片山」。
  const spanW = CANVAS_W * stepY;
  const ox = (W - spanW) / 2;
  const r = Math.max(1, Math.round(stepY / 2));
  const small = new Float32Array(CANVAS_W * CANVAS_H);
  for (let y = 0; y < CANVAS_H; y++) {
    for (let x = 0; x < CANVAS_W; x++) {
      let sum = 0, n = 0;
      const cx = Math.round(ox + x * stepY);
      const cy = Math.round(y * stepY);
      for (let dy = -r; dy < r; dy++) {
        for (let dx = -r; dx < r; dx++) {
          const sx = cx + dx, sy = cy + dy;
          if (sx < 0 || sy < 0 || sx >= W || sy >= H) { continue; }
          sum += grid[sy * W + sx];
          n++;
        }
      }
      small[y * CANVAS_W + x] = n > 0 ? sum / n : 0;
    }
  }
  return blur(small, CANVAS_W, CANVAS_H, SMOOTH_RADIUS);
}

/**
 * 可分离的 [1,2,1]/4 高斯，重复 `radius` 次。
 *
 * 一次 3 抽头只压掉一格的抖动，两次之后等效半径约 2 格——正好是「单格锯齿
 * 消失、山形还在」的位置。
 */
function blur(src, w, h, radius) {
  let cur = src;
  for (let pass = 0; pass < radius; pass++) {
    const tmp = new Float32Array(w * h);
    for (let y = 0; y < h; y++) {
      for (let x = 0; x < w; x++) {
        const a = cur[y * w + Math.max(0, x - 1)];
        const b = cur[y * w + x];
        const c = cur[y * w + Math.min(w - 1, x + 1)];
        tmp[y * w + x] = (a + 2 * b + c) / 4;
      }
    }
    const out = new Float32Array(w * h);
    for (let y = 0; y < h; y++) {
      for (let x = 0; x < w; x++) {
        const a = tmp[Math.max(0, y - 1) * w + x];
        const b = tmp[y * w + x];
        const c = tmp[Math.min(h - 1, y + 1) * w + x];
        out[y * w + x] = (a + 2 * b + c) / 4;
      }
    }
    cur = out;
  }
  return cur;
}

// ---------------------------------------------------------------- marching squares

/**
 * 单条等值线。
 *
 * 每个格子按四个角的「高于/低于阈值」查表，边上的交点用线性插值——插值是
 * 必须的，取格子中点会让等值线变成阶梯状，放大后一眼就看出来是像素格子。
 *
 * 返回的是**线段集合**，不是闭合环：把线段串成环要处理鞍点与开放端点，
 * 而绘制端只需要按顺序连点，因此这里直接输出折线（一段走完接下一段），
 * 用 `NaN` 分隔——JSON 里 `NaN` 不合法，所以改用 `-1` 哨兵，见 `simplify`。
 */
function marchingSquares(grid, W, H, level) {
  const segments = [];
  const at = (x, y) => grid[y * W + x];
  const lerp = (a, b, level, x0, y0, x1, y1) => {
    const t = (level - a) / (b - a);
    return [x0 + (x1 - x0) * t, y0 + (y1 - y0) * t];
  };
  for (let y = 0; y < H - 1; y++) {
    for (let x = 0; x < W - 1; x++) {
      const tl = at(x, y), tr = at(x + 1, y), br = at(x + 1, y + 1), bl = at(x, y + 1);
      let idx = 0;
      if (tl > level) idx |= 8;
      if (tr > level) idx |= 4;
      if (br > level) idx |= 2;
      if (bl > level) idx |= 1;
      if (idx === 0 || idx === 15) { continue; }
      const top = () => lerp(tl, tr, level, x, y, x + 1, y);
      const right = () => lerp(tr, br, level, x + 1, y, x + 1, y + 1);
      const bottom = () => lerp(bl, br, level, x, y + 1, x + 1, y + 1);
      const left = () => lerp(tl, bl, level, x, y, x, y + 1);
      switch (idx) {
        case 1: case 14: segments.push([left(), bottom()]); break;
        case 2: case 13: segments.push([bottom(), right()]); break;
        case 3: case 12: segments.push([left(), right()]); break;
        case 4: case 11: segments.push([top(), right()]); break;
        case 6: case 9: segments.push([top(), bottom()]); break;
        case 7: case 8: segments.push([left(), top()]); break;
        // 鞍点：两个角各算一次，用中心平均值判决连法
        case 5: {
          const c = (tl + tr + br + bl) / 4;
          if (c > level) { segments.push([left(), top()]); segments.push([bottom(), right()]); }
          else { segments.push([left(), bottom()]); segments.push([top(), right()]); }
          break;
        }
        case 10: {
          const c = (tl + tr + br + bl) / 4;
          if (c > level) { segments.push([top(), right()]); segments.push([left(), bottom()]); }
          else { segments.push([top(), left()]); segments.push([bottom(), right()]); }
          break;
        }
        default: break;
      }
    }
  }
  return segments;
}

/**
 * 把线段串成折线。
 *
 * 需要一个哈希把端点接起来：marching squares 输出的是无序线段，每条独立。
 * 键取整到 1e-4，因为插值交点是浮点，严格相等几乎不会命中。
 */
function chainSegments(segments) {
  const KEY = (p) => `${Math.round(p[0] * 1e4)},${Math.round(p[1] * 1e4)}`;
  const map = new Map();
  segments.forEach((s, i) => {
    for (const p of s) {
      const k = KEY(p);
      if (!map.has(k)) { map.set(k, []); }
      map.get(k).push(i);
    }
  });
  const used = new Array(segments.length).fill(false);
  const polylines = [];
  const other = (seg, p) => (KEY(seg[0]) === KEY(p) ? seg[1] : seg[0]);
  for (let i = 0; i < segments.length; i++) {
    if (used[i]) { continue; }
    used[i] = true;
    const line = [segments[i][0], segments[i][1]];
    // 向两端延伸，直到接不上
    for (let dir = 0; dir < 2; dir++) {
      for (;;) {
        const end = dir === 0 ? line[line.length - 1] : line[0];
        const cands = map.get(KEY(end)) || [];
        let next = -1;
        for (const j of cands) {
          if (!used[j]) { next = j; break; }
        }
        if (next < 0) { break; }
        used[next] = true;
        const p = other(segments[next], end);
        if (dir === 0) { line.push(p); } else { line.unshift(p); }
      }
    }
    if (line.length >= 2) { polylines.push(line); }
  }
  return polylines;
}

/** Douglas-Peucker。背景上的线只传达「形状」，0.6 px 的偏离看不出来。 */
function simplify(line, tol) {
  if (line.length < 3) { return line; }
  const keep = new Uint8Array(line.length);
  keep[0] = 1;
  keep[line.length - 1] = 1;
  const stack = [[0, line.length - 1]];
  while (stack.length) {
    const [a, b] = stack.pop();
    let maxD = -1, maxI = -1;
    const [ax, ay] = line[a];
    const [bx, by] = line[b];
    const dx = bx - ax, dy = by - ay;
    const len = Math.hypot(dx, dy) || 1e-9;
    for (let i = a + 1; i < b; i++) {
      const [px, py] = line[i];
      const d = Math.abs(dy * px - dx * py + bx * ay - by * ax) / len;
      if (d > maxD) { maxD = d; maxI = i; }
    }
    if (maxD > tol && maxI > 0) {
      keep[maxI] = 1;
      stack.push([a, maxI], [maxI, b]);
    }
  }
  const out = [];
  for (let i = 0; i < line.length; i++) { if (keep[i]) { out.push(line[i]); } }
  return out;
}

// ---------------------------------------------------------------- 主流程

/** 折线的总弧长（画布单位）。用来剔除 DEM 噪声碎片。 */
function pathLength(line) {
  let n = 0;
  for (let i = 1; i < line.length; i++) {
    n += Math.hypot(line[i][0] - line[i - 1][0], line[i][1] - line[i - 1][1]);
  }
  return n;
}

/**
 * 按目标层数反算等高距。
 *
 * `max - min` 是这张 3×3 瓦片里的相对高差；真正会被画出来的层数是
 * `(max - min) / interval`，但因为地形不是均匀分布，实际会少一些（有的阈值
 * 只切到画布边缘一小段）。所以挑「理论层数 ≥ target」的最小候选值，再让
 * `(max - min) / interval` 尽量贴近 target。
 */
function pickInterval(min, max, target) {
  const range = max - min;
  let best = NICE_STEPS[0];
  let bestScore = Infinity;
  for (const step of NICE_STEPS) {
    const levels = range / step;
    if (levels < 2) { continue; }
    // 主要判据是层数接近 target；超出 target 一点比不足好（不足会显得空）。
    const score = Math.abs(levels - target) + (levels < target ? 1.5 : 0);
    if (score < bestScore) { bestScore = score; best = step; }
  }
  return best;
}

async function buildPlace(place) {
  process.stdout.write(`  ${place.name} (${place.lat}, ${place.lon}) ... `);
  const grid = buildElevation(place);
  let min = Infinity, max = -Infinity;
  for (let i = 0; i < grid.length; i++) {
    if (grid[i] < min) { min = grid[i]; }
    if (grid[i] > max) { max = grid[i]; }
  }
  const interval = pickInterval(min, max, place.target);
  // 等高线从「高于最低点一个等高距」起步：贴着最低点的那条线会沿着画布
  // 边缘走，画出来是一条无意义的边框。
  const first = Math.ceil(min / interval) * interval;
  const levels = [];
  let idxCount = 0;
  for (let h = first; h < max; h += interval) {
    idxCount++;
    const segs = marchingSquares(grid, CANVAS_W, CANVAS_H, h);
    if (segs.length === 0) { continue; }
    const polylines = chainSegments(segs);
    const paths = [];
    let points = 0;
    for (const line of polylines) {
      // 先按弧长筛掉碎片，再简化——反过来会让「简化后只剩 3 个点」的长线
      // 和真正的碎片混在一起，无法区分。
      if (pathLength(line) < MIN_PATH_LEN) { continue; }
      const s = simplify(line, TOLERANCE);
      if (s.length < 2) { continue; }
      const flat = [];
      for (const [px, py] of s) {
        flat.push(Math.max(0, Math.min(CANVAS_W - 1, Math.round(px))));
        flat.push(Math.max(0, Math.min(CANVAS_H - 1, Math.round(py))));
      }
      paths.push(flat);
      points += s.length;
    }
    if (paths.length === 0) { continue; }
    levels.push({ h: h, idx: idxCount % 5 === 0, paths: paths });
  }
  const totalPoints = levels.reduce((n, l) => n + l.paths.reduce((m, p) => m + p.length / 2, 0), 0);
  const text = encodeText(place.key, interval, min, max, levels);
  fs.writeFileSync(path.join(OUT_DIR, `${place.key}.txt`), text);
  console.log(`${levels.length} levels (interval ${interval} m), ${totalPoints} pts, ${(text.length / 1024).toFixed(1)} KB, ${Math.round(min)}–${Math.round(max)} m`);
  return { key: place.key, levels: levels.length, points: totalPoints, bytes: text.length, min, max, interval };
}

/**
 * 序列化成上面注释里那个纯文本格式。
 *
 * 头部一行给容器尺寸信息（等高距与海拔范围），`L` 行开一层，其余每行一条路径。
 * 增量编码只对**路径内**生效：跨路径继续累加会把误差一路带下去，而每条线的
 * 起点是绝对坐标，丢掉一条也不会让后面的整体漂移。
 */
function encodeText(key, interval, min, max, levels) {
  const out = [`${key} ${interval} ${Math.round(min)} ${Math.round(max)} ${CANVAS_W} ${CANVAS_H}`];
  for (const level of levels) {
    out.push(`L ${level.h} ${level.idx ? 1 : 0}`);
    for (const flat of level.paths) {
      const parts = [String(flat[0]), String(flat[1])];
      let px = flat[0], py = flat[1];
      for (let i = 2; i < flat.length; i += 2) {
        parts.push(String(flat[i] - px), String(flat[i + 1] - py));
        px = flat[i];
        py = flat[i + 1];
      }
      out.push(parts.join(' '));
    }
  }
  return out.join('\n') + '\n';
}

async function main() {
  const onlyArg = process.argv.indexOf('--only');
  const only = onlyArg > 0 ? process.argv[onlyArg + 1] : null;
  if (!fs.existsSync(OUT_DIR)) { fs.mkdirSync(OUT_DIR, { recursive: true }); }
  const proxy = process.env.HTTPS_PROXY || process.env.https_proxy;
  if (proxy) { console.log(`via ${proxy} (curl)`); }
  console.log(`writing ${path.relative(ROOT, OUT_DIR)}`);
  const results = [];
  for (const place of PLACES) {
    if (only && place.key !== only) { continue; }
    try {
      results.push(await buildPlace(place));
    } catch (e) {
      console.error(`\n  FAILED ${place.key}: ${e.message}`);
      process.exitCode = 1;
    }
  }
  console.log(`\n== summary`);
  for (const r of results) {
    console.log(`  ${r.key.padEnd(12)} ${String(r.levels).padStart(3)} levels  ${String(r.points).padStart(6)} pts  ${(r.bytes / 1024).toFixed(1).padStart(6)} KB  ${Math.round(r.min)}–${Math.round(r.max)} m`);
  }
  console.log(`  total ${(results.reduce((n, r) => n + r.bytes, 0) / 1024).toFixed(1)} KB`);
}

main().catch((e) => { console.error(e); process.exit(1); });
