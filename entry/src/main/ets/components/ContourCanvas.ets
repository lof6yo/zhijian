import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ContourGeometry, ContourLevel } from '../common/ContourGeometry';
import {
  ContourTheme, ContourInk, ContourThemes,
  CONTOUR_FADE_TOP, CONTOUR_FADE_BOTTOM, CONTOUR_FADE_MIN
} from '../common/ContourTheme';

const DOMAIN = 0x0000;
const TAG = 'ContourCanvas';

/**
 * 等高线背景层。
 *
 * 一个 `Canvas` 铺满整屏，把一份**真实地形**的等高线按 cover 缩放描上去，再在
 * 顶部与底部各做一条线性淡出，让线与标题栏 / 页签栏让位。
 *
 * ## 为什么是 Canvas 而不是一堆 `Path` 组件
 *
 * 五个地点合计 100–700 条折线（`taklamakan` 有 699 条）。用 ArkUI 组件画，每条
 * 都要一个节点，首屏要建上千个节点——这是「背景」在拖慢「笔记」的典型形态。
 * Canvas 是一次性栅格化：节点数恒为 1，绘制成本只跟点数和有关，而点数已经被
 * 构建期简化过（TOLERANCE 1.0）。
 *
 * ## 为什么几何在构建期提取
 *
 * 运行期要么打包 DEM 位图（每地点 3×3 瓦片 ≈ 1.5 MB，五个 7 MB+），要么联网
 * 取瓦片（一个本地优先的笔记应用不该为了背景联网）。所以 `tools/gen-contours.js`
 * 构建期从公开 DEM 提一次线，运行期只读一份 10–30 KB 的文本。
 *
 * ## 为什么淡出用 `destination-out` 而不是盖一层底色
 *
 * 底色是 160° 的三段渐变，同一个 y 上左右两侧的颜色本来就不同。盖一层固定色
 * 会在淡出带边界露出一条与底色对不上的横带；`destination-out` 按 alpha 擦除，
 * 与底色无关，深浅两套主题共用一条遮罩。
 */
@ComponentV2
export struct ContourCanvas {
  /** 几何文件名（`rawfile/contours/{key}.txt`），同时也是主题的 key。 */
  @Param themeKey: string = 'huangshan';
  @Param isDark: boolean = false;

  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private context: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private canvasW: number = 0;
  private canvasH: number = 0;
  /** 最后一次成功绘制时的输入；三个都一致就跳过重绘。 */
  private drawnKey: string = '';
  private drawnDark: boolean = false;
  private drawnW: number = 0;
  private drawnH: number = 0;
  /**
   * 解析结果的进程级缓存。
   *
   * 切主题是「读一次 30 KB 文本 + 逐行 parseInt」——16 个点的路径还行，黄山有
   * 5608 个点，来回切五次就是五次全量解析。缓存放在 struct 外面（模块级），
   * 所以组件重建（切页签、翻转主题）都还在。
   */
  private static readonly cache: Map<string, ContourGeometry> = new Map<string, ContourGeometry>();

  /**
   * 主题或明暗变化时立刻重绘。
   *
   * 两个都在这里而不是 `aboutToAppear`：`@Param` 变了组件实例是复用的，
   * `aboutToAppear` 不会再跑一次，界面会一直停在第一套配色上。
   */
  @Monitor('themeKey', 'isDark')
  onInputChanged(): void {
    this.redraw();
  }

  build() {
    Canvas(this.context)
      .width('100%')
      .height('100%')
      .onReady(() => {
        this.redraw();
      })
      .onAreaChange((_oldValue: Area, newValue: Area) => {
        const w: number = Number.parseFloat(`${newValue.width}`);
        const h: number = Number.parseFloat(`${newValue.height}`);
        if (!(w > 0) || !(h > 0)) {
          return;
        }
        if (Math.abs(w - this.canvasW) < 0.5 && Math.abs(h - this.canvasH) < 0.5) {
          return;
        }
        this.canvasW = w;
        this.canvasH = h;
        this.redraw();
      })
  }

  // ------------------------------------------------------------------ 数据

  /** 读并解析一份几何；失败返回 `null`（不画线，而不是画一半）。 */
  private load(key: string): ContourGeometry | null {
    const cached: ContourGeometry | undefined = ContourCanvas.cache.get(key);
    if (cached !== undefined) {
      return cached;
    }
    try {
      const host = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const bytes: Uint8Array = host.resourceManager.getRawFileContentSync(`contours/${key}.txt`);
      const text: string = util.TextDecoder.create('utf-8').decodeToString(bytes);
      const geometry: ContourGeometry | null = ContourGeometry.parse(text);
      if (geometry === null) {
        hilog.error(DOMAIN, TAG, 'parse failed: %{public}s', key);
        return null;
      }
      ContourCanvas.cache.set(key, geometry);
      return geometry;
    } catch (error) {
      // 背景是装饰：读不到就安静地不画，不要把主界面拖进异常路径。
      hilog.error(DOMAIN, TAG, 'load failed: %{public}s', key);
      return null;
    }
  }

  // ------------------------------------------------------------------ 绘制

  private redraw(): void {
    if (!(this.canvasW > 0) || !(this.canvasH > 0)) {
      return;
    }
    if (this.drawnKey === this.themeKey && this.drawnDark === this.isDark &&
      Math.abs(this.drawnW - this.canvasW) < 0.5 && Math.abs(this.drawnH - this.canvasH) < 0.5) {
      return;
    }
    const geometry: ContourGeometry | null = this.load(this.themeKey);
    if (geometry === null) {
      return;
    }

    const ctx: CanvasRenderingContext2D = this.context;
    const w: number = this.canvasW;
    const h: number = this.canvasH;
    ctx.clearRect(0, 0, w, h);

    const theme: ContourTheme = ContourThemes.byKey(this.themeKey);
    const ink: ContourInk = theme.ink(this.isDark);

    // cover：两份比例取大的那个，保证铺满且不变形。画布（448×758）本来就是
    // 屏幕比例，所以在手机上 scale ≈ 1；平板上会放大，横屏上会纵向裁掉两侧。
    const scale: number = Math.max(w / geometry.width, h / geometry.height);
    // 居中：多出来的部分两侧均分，山势落在画面中间而不是贴边。
    const offsetX: number = (w - geometry.width * scale) / 2;
    const offsetY: number = (h - geometry.height * scale) / 2;

    ctx.lineCap = 'round';
    ctx.lineJoin = 'round';

    // 两档线，各一次 stroke：一次 `beginPath` 里塞进整档的所有 moveTo/lineTo
    // 子路径，所以 699 条折线只要 2 次 stroke 而不是 699 次。
    //
    // 顺带一个正确性上的好处：同一次 stroke 里的重叠段按**并集覆盖率**栅格化，
    // 不会因为两条线交叠而叠出更黑的一块。逐条描边会——等高线在陡坡上本来就
    // 挤，那会让山脊糊成一片深色。
    this.strokeLevels(ctx, geometry.levels, false, ink, scale, offsetX, offsetY);
    this.strokeLevels(ctx, geometry.levels, true, ink, scale, offsetX, offsetY);

    this.fadeEdges(ctx, w, h);

    this.drawnKey = this.themeKey;
    this.drawnDark = this.isDark;
    this.drawnW = w;
    this.drawnH = h;
  }

  /**
   * 画一档线（普通线或计曲线）。
   *
   * 分成两趟而不是一趟里逐层改样式：同一档的所有层共用一次 `strokeStyle` 赋值，
   * 省掉每层一次状态切换；层数有十几层，改动量不大但代码更直白——「凡是计曲线，
   * 都用这一套笔」。
   */
  private strokeLevels(ctx: CanvasRenderingContext2D, levels: ContourLevel[],
    indexOnly: boolean, ink: ContourInk,
    scale: number, offsetX: number, offsetY: number): void {
    const isIndex: boolean = indexOnly;
    const color: string = isIndex ? ink.index : ink.line;
    const alpha: number = isIndex ? ink.indexAlpha : ink.lineAlpha;
    const width: number = isIndex ? ink.indexWidth : ink.lineWidth;

    let any: boolean = false;
    ctx.beginPath();
    for (let i = 0; i < levels.length; i++) {
      const level: ContourLevel = levels[i];
      if (level.index !== isIndex) {
        continue;
      }
      for (let p = 0; p < level.paths.length; p++) {
        const path: number[] = level.paths[p];
        for (let k = 0; k + 1 < path.length; k += 2) {
          const x: number = offsetX + path[k] * scale;
          const y: number = offsetY + path[k + 1] * scale;
          if (k === 0) {
            ctx.moveTo(x, y);
          } else {
            ctx.lineTo(x, y);
          }
        }
        any = true;
      }
    }
    if (!any) {
      return;
    }
    ctx.strokeStyle = ContourThemes.withAlpha(color, alpha);
    ctx.lineWidth = width;
    ctx.stroke();
  }

  /**
   * 顶部与底部淡出。
   *
   * `destination-out` 按**源 alpha** 擦除，所以首端 alpha 0.94 表示「只剩 6%」
   * ——就是 `CONTOUR_FADE_MIN`。留 6% 而不是全擦：全擦会在带子边界上留下一条
   * 干净的横线，线在那里突然消失，比线存在更显眼。
   *
   * 深浅两套共用同一条遮罩：它擦的是 alpha，与底色无关。
   */
  private fadeEdges(ctx: CanvasRenderingContext2D, w: number, h: number): void {
    const eraseMax: number = 1 - CONTOUR_FADE_MIN;
    const top: number = Math.min(CONTOUR_FADE_TOP, h / 2);
    const bottom: number = Math.min(CONTOUR_FADE_BOTTOM, h / 2);

    ctx.globalCompositeOperation = 'destination-out';

    const topGrad: CanvasGradient = ctx.createLinearGradient(0, 0, 0, top);
    topGrad.addColorStop(0, `rgba(0,0,0,${eraseMax.toFixed(3)})`);
    topGrad.addColorStop(1, 'rgba(0,0,0,0)');
    ctx.fillStyle = topGrad;
    ctx.fillRect(0, 0, w, top);

    const botGrad: CanvasGradient = ctx.createLinearGradient(0, h - bottom, 0, h);
    botGrad.addColorStop(0, 'rgba(0,0,0,0)');
    botGrad.addColorStop(1, `rgba(0,0,0,${eraseMax.toFixed(3)})`);
    ctx.fillStyle = botGrad;
    ctx.fillRect(0, h - bottom, w, bottom);

    ctx.globalCompositeOperation = 'source-over';
  }
}
