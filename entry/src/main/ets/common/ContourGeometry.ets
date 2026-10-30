/**
 * 等高线几何的解析与缓存。
 *
 * 数据是 `tools/gen-contours.js` 的构建期产物，落在
 * `rawfile/contours/{key}.txt`。格式（首行固定六个数）：
 *
 *     huangshan 100 178 1808 448 758   <- key 等高距 最低海拔 最高海拔 画布宽 画布高
 *     L 300 0                          <- 开一层：海拔、是否计曲线
 *     224 379 6 0 -2 1 ...             <- 一条路径：首点绝对，其后全是增量
 *
 * ## 为什么是纯文本而不是 JSON
 *
 * ArkTS 里 `JSON.parse` 返回 `Object`。要从里面取出「层数组 → 路径数组 →
 * 数字数组」，只有两条路：全程 `ESObject`（ArkTS 禁止），或者写一长串 `as`
 * 断言（任何一层缺失就在运行期抛）。纯文本按行切、按空格切，全是 `string[]`
 * 与 `number`，一处断言都不需要——这不是为了省事，是因为类型系统在这条路上
 * 帮不上忙，越少的类型跳跃越安全。
 *
 * ## 为什么增量编码
 *
 * 相邻点通常只差几个单位，`12 0 9 -1` 比 `[140,74,152,74]` 短一半以上。五个
 * 地点从 158 KB 降到 109 KB，而 HAP 的 release 基线本来只有 1.32 MB。增量只
 * 在**路径内**生效：每条线的起点是绝对坐标，丢掉一条不会让后面的整体漂移。
 */
export class ContourLevel {
  /** 这一层的高程（米），只用于调试与将来的高程标注，绘制不读它。 */
  height: number;
  /** 计曲线（每五条一条）。绘制时加粗、加重。 */
  index: boolean;
  /** 每条路径是扁平的 `[x0, y0, x1, y1, ...]`，单位是画布坐标。 */
  paths: number[][];

  constructor(height: number, index: boolean, paths: number[][]) {
    this.height = height;
    this.index = index;
    this.paths = paths;
  }
}

export class ContourGeometry {
  key: string;
  /** 等高距（米）。 */
  interval: number;
  min: number;
  max: number;
  /** 画布的逻辑宽高。绘制端按它做 cover 缩放，与屏幕密度无关。 */
  width: number;
  height: number;
  levels: ContourLevel[];

  constructor(key: string, interval: number, min: number, max: number,
    width: number, height: number, levels: ContourLevel[]) {
    this.key = key;
    this.interval = interval;
    this.min = min;
    this.max = max;
    this.width = width;
    this.height = height;
    this.levels = levels;
  }

  /**
   * 解析一份 `.txt`。失败返回 `null`，由调用方决定「不画线」而不是画一半。
   *
   * 宁可整份不画也不画错：背景少一层地形线与画出一堆错位的曲线，后者要严重
   * 得多——前者只是「这个主题没有纹理」。
   */
  static parse(text: string): ContourGeometry | null {
    const lines: string[] = text.split('\n');
    if (lines.length === 0) {
      return null;
    }
    const head: string[] = lines[0].trim().split(' ');
    if (head.length < 6) {
      return null;
    }
    const key: string = head[0];
    const interval: number = Number.parseInt(head[1], 10);
    const min: number = Number.parseInt(head[2], 10);
    const max: number = Number.parseInt(head[3], 10);
    const width: number = Number.parseInt(head[4], 10);
    const height: number = Number.parseInt(head[5], 10);
    if (!(width > 0) || !(height > 0)) {
      return null;
    }

    const levels: ContourLevel[] = [];
    let current: ContourLevel | null = null;
    for (let i = 1; i < lines.length; i++) {
      const line: string = lines[i];
      if (line.length === 0) {
        continue;
      }
      if (line.charAt(0) === 'L' && line.charAt(1) === ' ') {
        const parts: string[] = line.split(' ');
        if (parts.length < 3) {
          continue;
        }
        current = new ContourLevel(Number.parseInt(parts[1], 10), parts[2] === '1', []);
        levels.push(current);
        continue;
      }
      if (current === null) {
        continue;
      }
      const nums: string[] = line.split(' ');
      if (nums.length < 4) {
        // 单点路径画不出线，直接跳过而不是留一个孤立点。
        continue;
      }
      const path: number[] = [];
      let x: number = Number.parseInt(nums[0], 10);
      let y: number = Number.parseInt(nums[1], 10);
      path.push(x);
      path.push(y);
      for (let k = 2; k + 1 < nums.length; k += 2) {
        x += Number.parseInt(nums[k], 10);
        y += Number.parseInt(nums[k + 1], 10);
        path.push(x);
        path.push(y);
      }
      current.paths.push(path);
    }

    if (levels.length === 0) {
      return null;
    }
    return new ContourGeometry(key, interval, min, max, width, height, levels);
  }
}
