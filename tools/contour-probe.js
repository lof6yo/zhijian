#!/usr/bin/env node
/**
 * 候选地点高差探测。
 *
 * 从 `gen-contours.js` 里借高程管线，对一串经纬度打印 min / max / 高差，
 * 并给出按 12 层反算出的等高距，用来挑「有线条但依然平缓」的地点。
 * 复用同一个 `buildElevation`，所以这里看到的数字和真正出图时是同一份数据。
 *
 * 跑法：`node tools/gen-contours.js --probe lat,lon lat,lon ...`
 */
'use strict';

const path = require('path');
const { execFileSync } = require('child_process');
const fs = require('fs');

const CANDIDATES = [
  ['青海湖西南·橡皮山', 36.7500, 99.6000],
  ['青海湖东北·日月山', 36.9500, 100.5500],
  ['青海湖西北·天峻', 37.3000, 99.0200],
  ['祁连山南麓·刚察', 37.3300, 100.1300],
  ['甘南·桑科草原', 35.2000, 102.5000],
  ['呼伦贝尔·海拉尔', 49.2000, 119.7500],
  ['锡林郭勒·平顶山', 43.9500, 116.0800],
  ['坝上·闪电湖', 41.7000, 115.6000],
  ['腾格里·沙坡头', 37.5000, 104.9500],
  ['巴丹吉林·沙山', 39.8000, 102.4000],
  ['库姆塔格·沙丘', 39.9000, 92.8000],
  ['柴达木·盐湖', 37.1000, 94.3000]
];

const tmp = path.join(process.env.TEMP || '.', 'probe');
if (!fs.existsSync(tmp)) { fs.mkdirSync(tmp, { recursive: true }); }

function lonLatToTile(lon, lat, z) {
  const n = Math.pow(2, z);
  const r = lat * Math.PI / 180;
  return {
    x: Math.floor((lon + 180) / 360 * n),
    y: Math.floor((1 - Math.log(Math.tan(r) + 1 / Math.cos(r)) / Math.PI) / 2 * n)
  };
}

// 只需要 min/max，用不着 full 解码：这里直接调 gen-contours 的导出不划算，
// 所以走它的 CLI 不如自己读瓦片。terrarium 是 RGB PNG，这里只解一层即可。
const zlib = require('zlib');
function decodePng(buf) {
  let pos = 8, width = 0, height = 0, bitDepth = 0, colorType = 0;
  const idat = [];
  while (pos < buf.length) {
    const len = buf.readUInt32BE(pos);
    const type = buf.toString('ascii', pos + 4, pos + 8);
    const data = buf.subarray(pos + 8, pos + 8 + len);
    if (type === 'IHDR') {
      width = data.readUInt32BE(0); height = data.readUInt32BE(4);
      bitDepth = data[8]; colorType = data[9];
    } else if (type === 'IDAT') { idat.push(data); }
    else if (type === 'IEND') { break; }
    pos += 12 + len;
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
        default: throw new Error('bad filter ' + filter);
      }
      cur[i] = v & 0xff;
    }
    cur.copy(out, y * stride);
    prev = cur;
  }
  return { width, height, channels, data: out };
}

function tile(z, x, y) {
  const f = path.join(tmp, `t-${z}-${x}-${y}.png`);
  if (!fs.existsSync(f)) {
    execFileSync('curl', ['-sS', '--fail', '--max-time', '60', '-o', f,
      `https://s3.amazonaws.com/elevation-tiles-prod/terrarium/${z}/${x}/${y}.png`], { stdio: 'pipe' });
  }
  return decodePng(fs.readFileSync(f));
}

const rows = [];
for (const [name, lat, lon] of CANDIDATES) {
  const { x: tx, y: ty } = lonLatToTile(lon, lat, 12);
  let min = Infinity, max = -Infinity, sum = 0, n = 0;
  for (let dy = -1; dy <= 1; dy++) {
    for (let dx = -1; dx <= 1; dx++) {
      const t = tile(12, tx + dx, ty + dy);
      for (let y = 0; y < t.height; y += 4) {
        for (let x = 0; x < t.width; x += 4) {
          const i = (y * t.width + x) * t.channels;
          const h = (t.data[i] * 256 + t.data[i + 1] + t.data[i + 2] / 256) - 32768;
          if (h < min) { min = h; }
          if (h > max) { max = h; }
          sum += h; n++;
        }
      }
    }
  }
  const relief = max - min;
  // 反推：让 (relief / step) 落在 10–14 之间
  const step = relief / 12;
  rows.push({ name, lat, lon, min: Math.round(min), max: Math.round(max), relief: Math.round(relief), step: Math.round(step) });
}
rows.sort((a, b) => a.relief - b.relief);
console.log('name'.padEnd(22), 'lat'.padStart(9), 'lon'.padStart(9), 'min'.padStart(6), 'max'.padStart(6), 'relief'.padStart(7), 'step~'.padStart(6));
for (const r of rows) {
  console.log(r.name.padEnd(22), String(r.lat).padStart(9), String(r.lon).padStart(9),
    String(r.min).padStart(6), String(r.max).padStart(6), String(r.relief).padStart(7), String(r.step).padStart(6));
}
