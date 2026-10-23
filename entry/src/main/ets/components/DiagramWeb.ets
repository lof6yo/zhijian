import { webview } from '@kit.ArkWeb';
import { hilog } from '@kit.PerformanceAnalysisKit';

/**
 * 「用 Web 渲染的那一块」的唯一入口：公式、Mermaid、ECharts。
 *
 * ## 为什么只有这几类走 Web
 *
 * 正文走 WebView 会让原生滚动、系统字号、文本选择、批注坐标一起失效，一屏几十
 * 个块经 DOM 布局也会卡。但公式排版（KaTeX）与图表（Mermaid / ECharts）的复杂度
 * 不值得自研，而它们天然是**独立的一块**——只需要「给定源码 → 得到一张固定高度的
 * 图」。所以判据是：能不能被当成一个尺寸确定的块。公式和图能，正文不能。
 *
 * 渲染全部离线：`rawfile/render/<kind>.html` 各自加载 `vendor/` 下的库，不联网。
 * 授权见 `rawfile/render/LICENSES.md`（KaTeX MIT / Mermaid MIT / ECharts Apache-2.0）。
 *
 * ## 两个方向都要走桥，不能只走一边
 *
 * - **ArkTS → 页面**：没有直接调用入口，所以 `onPageEnd` 时先用 `runJavaScript`
 *   注入 `window.__onRender`，再把载荷塞进 `window.render(...)`。
 * - **页面 → ArkTS**：`javaScriptProxy` 注册的 `nativeHost` 对象。页面的
 *   `__onRender` 转发到 `nativeHost.onRender(h, ok, err)`，ArkTS 收到后才知道这块
 *   该多高。
 *
 * 之所以不用 `postMessage`：`WebMessagePort` 需要在页面加载**之前**建好端口并注入，
 * 而 `rawfile` 页面的加载时机不受控；`javaScriptProxy` 在 `onPageEnd` 注入即可，
 * 且页面侧自带重试队列（见 harness 的 `__onRender` 重试逻辑）。
 *
 * ## 高度必须被钳制
 *
 * 一个渲染失败的页面若报回 `0`，块会塌成一条线；若报回一个荒谬的大数（引擎在
 * 宽度为 0 时量出无穷大），它会顶掉整篇文章的排版。所以高度有下限、上限与
 * **超时兜底**：超过 `FUSE_MS` 没有回音就当成失败，把块显示成「渲染超时」，
 * 而不是永远空着。
 */
const DOMAIN = 0x0000;
const TAG = 'HMStartDiagram';

/** 没有回音的最长等待。到点按失败处理。 */
const FUSE_MS = 6000;
/** 高度下限：一行文字的高度，避免 0 高度让块消失。 */
const MIN_HEIGHT = 24;
/** 高度上限：超过就当引擎量错了。 */
const MAX_HEIGHT = 4000;

/**
 * 注入到页面里的桥接脚本。
 *
 * `JSON.stringify` **两次**：一次把载荷变成 JSON 文本，一次把那串文本变成合法的
 * JS 字符串字面量。少了第二层，正文里一个引号就能截断脚本、让整块静默失效。
 */
function bridgeScript(payloadJson: string): string {
  const literal = JSON.stringify(payloadJson);
  return `(function(){
  window.__onRender = function(h, ok, err){
    try { nativeHost.handleRender(h, ok, err || ''); } catch (e) {}
  };
  if (typeof window.render === 'function') {
    window.render(${literal});
  }
})();`;
}

/** 页面脚本调用 ArkTS 的入口。方法名必须与注入脚本里的 `nativeHost.handleRender` 一致。 */
class DiagramBridge {
  /** 由组件构造时注入，避免把 `this` 泄漏进 Web 侧。 */
  onRender: (height: number, ok: boolean, err: string) => void = () => {};

  /**
   * Web 侧回调。参数来自 JS，必须当成不可信输入：`h` 可能不是数字、
   * 可能是负数、可能大到离谱。
   */
  handleRender(height: number, ok: boolean, err: string): void {
    this.onRender(height, ok, err);
  }
}

/**
 * 一个用 Web 渲染的块。
 *
 * `kind` 决定加载哪个 harness，也决定「渲染失败时该显示什么」。
 */
@ComponentV2
export struct DiagramWeb {
  /** `katex` / `mermaid` / `echarts` —— 必须与 `rawfile/render/` 下的文件名一致。 */
  @Param kind: string = 'katex';
  /** 源码：LaTeX / Mermaid 定义 / ECharts option 的 JSON 文本。 */
  @Param code: string = '';
  @Param dark: boolean = false;
  /** 正文字号 px；公式跟它走，图表用它算 Mermaid 的 fontSize。 */
  @Param fontPx: number = 17;
  @Param textColor: string = '#1A1A1C';
  @Param accent: string = '#0A59F7';
  /** 卡片底色。传 `transparent` 让沉浸光感透出来。 */
  @Param bg: string = 'transparent';

  /** 量到的高度（vp）。0 表示还没量到。 */
  @Local blockHeight: number = 0;
  @Local failed: boolean = false;
  @Local failText: string = '';

  private controller: webview.WebviewController = new webview.WebviewController();
  private bridge: DiagramBridge = new DiagramBridge();
  private fuse: number = -1;
  private rendered: boolean = false;

  aboutToAppear(): void {
    this.bridge.onRender = (height: number, ok: boolean, err: string) => {
      this.applyReport(height, ok, err);
    };
    this.armFuse();
  }

  aboutToDisappear(): void {
    this.disarmFuse();
  }

  /** 计划一次超时。重复渲染时先撤旧的，避免两把定时器互相打架。 */
  private armFuse(): void {
    this.disarmFuse();
    this.fuse = setTimeout(() => {
      if (!this.rendered) {
        this.failed = true;
        this.failText = '渲染超时';
        this.blockHeight = MIN_HEIGHT;
        hilog.warn(DOMAIN, TAG, 'render timed out kind=%{public}s', this.kind);
      }
    }, FUSE_MS);
  }

  private disarmFuse(): void {
    if (this.fuse !== -1) {
      clearTimeout(this.fuse);
      this.fuse = -1;
    }
  }

  /**
   * 处理页面报回的高度。
   *
   * 页面会**多次**上报（KaTeX 在字体就绪后会报第二次，ResizeObserver 在宽度变化时
   * 再报），所以这里必须幂等：以最后一次为准，绝不做累加。已经失败的块也要允许
   * 后续成功上报把它救回来——迟到的成功比永远失败好。
   */
  private applyReport(height: number, ok: boolean, err: string): void {
    if (!ok) {
      this.rendered = true;
      this.failed = true;
      this.failText = err.length > 0 ? err : '渲染失败';
      this.blockHeight = MIN_HEIGHT;
      hilog.warn(DOMAIN, TAG, 'render failed kind=%{public}s err=%{public}s', this.kind, err);
      return;
    }
    let h = height;
    if (!Number.isFinite(h) || h <= 0) {
      // 页面量不出高度：别把块压成 0，那看起来像没渲染。
      h = MIN_HEIGHT;
    }
    if (h < MIN_HEIGHT) {
      h = MIN_HEIGHT;
    }
    if (h > MAX_HEIGHT) {
      h = MAX_HEIGHT;
    }
    this.rendered = true;
    this.failed = false;
    this.failText = '';
    this.blockHeight = Math.ceil(h);
    this.disarmFuse();
  }

  private payload(): string {
    // 一个显式的类而不是内联字面量：ArkTS 不接受无类型对象字面量。
    const data: DiagramPayload = {
      code: this.code,
      dark: this.dark,
      fontPx: this.fontPx,
      bg: this.bg,
      textColor: this.textColor,
      accent: this.accent
    };
    return JSON.stringify(data);
  }

  private push(): void {
    if (this.code.length === 0) {
      return;
    }
    try {
      this.rendered = false;
      this.controller.runJavaScript(bridgeScript(this.payload()));
    } catch (e) {
      // 页面还没好：`onPageEnd` 会再推一次，这里不要标失败。
      hilog.debug(DOMAIN, TAG, 'push before page ready kind=%{public}s', this.kind);
    }
  }

  build() {
    Column() {
      if (this.failed) {
        this.FailCard()
      } else {
        Web({ src: $rawfile(`render/${this.kind}.html`), controller: this.controller })
          .width('100%')
          // 量到高度之前给 1 vp，而不是 0：0 高度的 Web 节点可能根本不参与布局，
          // 页面里的量高逻辑于是永远不跑，块就死等超时。1 vp 既让它完成布局，
          // 又在视觉上等于不存在。
          .height(this.blockHeight > 0 ? this.blockHeight : 1)
          .backgroundColor(Color.Transparent)
          .javaScriptAccess(true)
          // 不开放 DOM 存储：这几个页面只画画，不需要持久化。
          // `fileAccess` 保持默认 —— rawfile 的子资源（`vendor/*.js`、字体）
          // 走的是资源解析，关掉它会让页面加载到一个没有库的空壳。
          .domStorageAccess(false)
          .imageAccess(true)
          // 缩放交给外层滚动容器，Web 自己不缩放——否则公式会被捏成两套字号。
          .zoomAccess(false)
          .horizontalScrollBarAccess(false)
          .verticalScrollBarAccess(false)
          // 页面内的空白区域不该吃掉外层的滚动。
          .nestedScroll({
            scrollForward: NestedScrollMode.PARENT_FIRST,
            scrollBackward: NestedScrollMode.SELF_FIRST
          })
          .javaScriptProxy({
            object: this.bridge,
            name: 'nativeHost',
            methodList: ['handleRender'],
            controller: this.controller
          })
          .onPageEnd(() => {
            this.push();
          })
          .onErrorReceive(() => {
            hilog.error(DOMAIN, TAG, 'web error kind=%{public}s', this.kind);
            this.applyReport(0, false, '页面加载失败');
          })
      }
    }
    .width('100%')
    .onAppear(() => {
      this.armFuse();
    })
  }

  /**
   * 失败态。必须画出**可读的东西**：一个空白块会让用户以为笔记内容丢了，
   * 而实际上只是这段公式/图的语法有问题。
   */
  @Builder
  FailCard() {
    Column({ space: 4 }) {
      Text(`${this.kind} 渲染失败`)
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_secondary'))
      Text(this.failText)
        .fontSize(11)
        .fontColor($r('app.color.text_secondary'))
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
      Text(this.code)
        .fontSize(11)
        .fontFamily('monospace')
        .fontColor($r('app.color.text_secondary'))
        .maxLines(6)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
    }
    .width('100%')
    .padding(10)
    .alignItems(HorizontalAlign.Start)
    .borderRadius(10)
    .border({ width: 1, color: $r('app.color.divider') })
  }
}

/**
 * 写给雏形页面的载荷。字段名必须与 `rawfile/render/*.html` 里的读取一致。
 */
interface DiagramPayload {
  code: string;
  dark: boolean;
  fontPx: number;
  bg: string;
  textColor: string;
  accent: string;
}
