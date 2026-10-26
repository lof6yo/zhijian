import { webview } from '@kit.ArkWeb';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { MathLite } from '../markdown/MathLite';

/**
 * 公式块的渲染器：**唯一**走 ArkWeb 的地方。
 *
 * ## 为什么只有公式走 Web
 *
 * 正文走 WebView 会让原生滚动、系统字号、文本选择、批注坐标一起失效，一屏几十
 * 个块经 DOM 布局也会卡。但公式排版（KaTeX）的复杂度不值得自研，而它天然是
 * **独立的一块**——只需要「给定 LaTeX → 得到一张固定高度的图」。判据是：能不能
 * 被当成一个尺寸确定的块。公式能，正文不能。
 *
 * ## 渲染全部离线
 *
 * `rawfile/render/katex.html` 加载 `vendor/katex.min.js` 与 `vendor/fonts/`，
 * 不联网。授权见 `rawfile/render/LICENSES.md`（KaTeX，MIT）。
 *
 * 包体上这是**唯一**保留的 Web 运行时。Mermaid 与 ECharts 曾经在这里，但
 * `MdView` 一直把它们渲染成「未接入」占位卡片，也就是 6.5 MB 的库从未执行过。
 * 图表需求改用原生方案，不再随包发一个跑不到的引擎。
 *
 * ## 两个方向都要走桥，不能只走一边
 *
 * - **ArkTS → 页面**：没有直接调用入口，所以 `onPageEnd` 时先用 `runJavaScript`
 *   注入 `window.__onRender`，再把载荷塞进 `window.render(...)`。
 * - **页面 → ArkTS**：`javaScriptProxy` 注册的 `nativeHost` 对象。页面的
 *   `__onRender` 转发到 `nativeHost.handleRender(h, ok, err)`，ArkTS 收到后才知道
 *   这块该多高。
 *
 * 之所以不用 `postMessage`：`WebMessagePort` 需要在页面加载**之前**建好端口并注入，
 * 而 `rawfile` 页面的加载时机不受控；`javaScriptProxy` 在 `onPageEnd` 注入即可，
 * 且页面侧自带重试队列（见 katex.html 的 `__onRender` 重试逻辑）。
 *
 * ## 高度必须被钳制
 *
 * 一个渲染失败的页面若报回 `0`，块会塌成一条线；若报回一个荒谬的大数（引擎在
 * 宽度为 0 时量出无穷大），它会顶掉整篇文章的排版。所以高度有下限、上限与
 * **超时兜底**：超过 `FUSE_MS` 没有回音就当成失败。
 *
 * ## 失败时显示 `MathLite` 的线性化结果，不是一句「渲染失败」
 *
 * 用户要的是看懂那一行公式。KaTeX 起不来时，`MathLite` 能把 LaTeX 压成一行
 * Unicode 近似（`E = mc²`），这块就仍然是可读的排版，而不是一块报错卡片。
 */
const DOMAIN = 0x0000;
const TAG = 'HMStartFormula';

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
class FormulaBridge {
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
 * 一个公式块（`$$…$$`）。
 *
 * 只做块级公式。行内 `$…$` 不进来：一屏十几个内联公式就是十几个 WebView，
 * 那是把「一块不用排版的文字」换成十几个浏览器进程，行内公式改由 `MdView` 用
 * `MathLite` 线性化成 Unicode 文本。
 */
@ComponentV2
export struct FormulaWeb {
  /** LaTeX 源码（不含 `$$` 分隔符）。 */
  @Param code: string = '';
  @Param dark: boolean = false;
  /** 正文字号 px；公式跟它走。 */
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
  private bridge: FormulaBridge = new FormulaBridge();
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

  /**
   * 源码或主题变了就重新推给页面。
   *
   * **这一步不能省。** `LiveBlockEditor` 的预览块在同一个结构位置上复用，用户每敲
   * 一个字 `@Param code` 就换一次，但 `build()` 不会重跑 `push()`——Web 页里还是
   * 第一次那行公式。实测：把 `$$E = mc^2$$` 改成 `$$a^2+b^2=c^2$$` 之后，预览一直
   * 停在旧的渲染上，直到超时兜底把它变成「渲染超时」。
   *
   * 与 `LiveBlockEditor` 的草稿重播同理：`aboutToAppear` 只在挂载时跑一次，参数
   * 变化必须靠 `@Monitor` 接。
   */
  @Monitor('code', 'dark', 'fontPx')
  onSourceChanged(): void {
    if (this.code.trim().length === 0) {
      // 空公式（用户刚敲了 `$$` 还没写内容）：什么都不画。`build()` 里已经对空
      // 源码返回空节点，这里只需要把状态收干净，不让上一版公式留在屏上。
      this.disarmFuse();
      this.rendered = true;
      this.failed = false;
      this.failText = '';
      this.blockHeight = 0;
      return;
    }
    // 重新推之前先把失败态清掉：`build()` 会把 FailCard 换回 Web 节点，
    // 节点重建 → 重新加载 → `onPageEnd` 再推一次；页面已经就绪时直接推也行。
    this.failed = false;
    this.failText = '';
    this.rendered = false;
    this.armFuse();
    this.push();
  }

  /** 计划一次超时。重复渲染时先撤旧的，避免两把定时器互相打架。 */
  private armFuse(): void {
    this.disarmFuse();
    this.fuse = setTimeout(() => {
      if (!this.rendered) {
        this.failed = true;
        this.failText = '渲染超时';
        this.blockHeight = MIN_HEIGHT;
        hilog.warn(DOMAIN, TAG, 'render timed out');
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
      hilog.warn(DOMAIN, TAG, 'render failed err=%{public}s', err);
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
    const data: FormulaPayload = {
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
      hilog.debug(DOMAIN, TAG, 'push before page ready');
    }
  }

  build() {
    Column() {
      if (this.code.trim().length === 0) {
        // 空公式：不挂 Web。用户在块编辑器里刚敲出 `$$` 时每一次按键都会到这里，
        // 起一个 WebView 只为了画空白，代价是每敲一个字都要加载一次 KaTeX。
      } else if (this.failed) {
        this.FailCard()
      } else {
        Web({ src: $rawfile('render/katex.html'), controller: this.controller })
          .width('100%')
          // 量到高度之前给 1 vp，而不是 0：0 高度的 Web 节点可能根本不参与布局，
          // 页面里的量高逻辑于是永远不跑，块就死等超时。1 vp 既让它完成布局，
          // 又在视觉上等于不存在。
          .height(this.blockHeight > 0 ? this.blockHeight : 1)
          .backgroundColor(Color.Transparent)
          .javaScriptAccess(true)
          // 不开放 DOM 存储：这个页面只画画，不需要持久化。
          // `fileAccess` 保持默认 —— rawfile 的子资源（`vendor/katex.min.js`、字体）
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
            hilog.error(DOMAIN, TAG, 'web error');
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
   * 失败态：**画出公式本身**，只把原因放在下面一行小字里。
   *
   * 一个空白块会让用户以为笔记内容丢了；一个只写着「渲染失败」的卡片同样没用，
   * 因为那一行公式才是他要看的东西。`MathLite` 已经把 LaTeX 压成一行 Unicode
   * 近似，所以这里退回它——排版不完美，但读得懂。
   */
  @Builder
  FailCard() {
    Column({ space: 4 }) {
      Text(MathLite.linearize(this.code))
        .fontSize(this.fontPx)
        .fontColor(this.dark ? '#F2F2F7' : '#1A1A1C')
        .width('100%')
        .textAlign(TextAlign.Center)
      Text(this.failText)
        .fontSize(10)
        .fontColor($r('app.color.text_secondary'))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .padding(10)
    .borderRadius(10)
    .backgroundColor($r('app.color.md_math_bg'))
    .border({ width: 1, color: $r('app.color.md_math_border'), style: BorderStyle.Dashed })
  }
}

/**
 * 写给页面的载荷。字段名必须与 `rawfile/render/katex.html` 里的读取一致。
 */
interface FormulaPayload {
  code: string;
  dark: boolean;
  fontPx: number;
  bg: string;
  textColor: string;
  accent: string;
}
