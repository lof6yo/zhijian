import { EditResult, MarkdownEdits } from './MarkdownEdits';
import { FormatBar } from './FormatBar';

/**
 * 「记事本」式的整篇输入。
 *
 * ## 它是什么
 *
 * 一张占满屏幕的输入框，装的是整篇 Markdown 原文。没有块、没有预览面板、
 * 没有「这一块是什么类型」的标签——打开就写，写完点完成回到渲染视图。
 * 默认就走这条路，因为对一个只想记点东西的人来说，多出来的每一层面板都是
 * 需要理解的东西。
 *
 * ## 它不是什么
 *
 * 不是富文本编辑器。输入框里就是源码：`##`、`- `、`**` 都原样可见。这不是缺陷，
 * 而是**可预测性**：用户看得见自己敲了什么，也就能预判再敲一个字符会发生什么。
 * 想看排版就点「完成」，渲染视图立刻给出结果。
 *
 * ## 光标位置
 *
 * 打开时可以指定落点（用户点了哪一段，光标就落到那一段的开头），这样
 * 「点哪儿写哪儿」在整篇输入里依然成立，而不必先滚到文末再找位置。
 */
@ComponentV2
export struct WholeDocEditor {
  /** 初始原文。只在打开时设置一次；编辑过程中由组件自己持有草稿。 */
  @Param source: string = '';
  /** 打开时光标落点（字符偏移）。 */
  @Param initialCaret: number = 0;
  @Param bodySize: number = 17;
  @Param lineHeight: number = 120;
  @Param showFormatBar: boolean = false;
  @Param accentColor: string = '#0A59F7';

  @Local draft: string = '';
  @Local selStart: number = 0;
  @Local selEnd: number = 0;
  @Local seeded: string = '';

  @Event onChange: (text: string) => void = () => {};

  private controller: TextAreaController = new TextAreaController();
  /**
   * 上一次的草稿文本，仅供回车续写做差分。
   *
   * 必须和 `draft` **一起**赋值：续写本身就是一次程序性改文本，改完若只更新
   * `draft`，下一次 `onChange` 拿到的 `prev` 就落后一截，长度差不再等于 1，
   * 续写会从第二个回车起彻底失灵。
   */
  private prevDraft: string = '';

  aboutToAppear(): void {
    this.seed();
    this.focusNow();
  }

  /**
   * 外部原文变化时重新播种并落光标。
   *
   * 与块编辑器同一个理由：组件实例可能被复用，`aboutToAppear` 不会再跑，
   * 输入框就会留着上一次的内容。`source` 只在「打开」时变，所以不会与输入打架。
   */
  @Monitor('source')
  onSourceChange(monitor: IMonitor): void {
    this.seed();
    this.focusNow();
  }

  private seed(): void {
    if (this.seeded === this.source) {
      return;
    }
    this.seeded = this.source;
    this.draft = this.source;
    // 播种等于「换了一篇文本」：差分的基线也必须跟着重置，否则从 A 篇切到 B 篇
    // 的第一下回车会被当成「B 篇在 A 篇末尾多了一个换行」。
    this.prevDraft = this.source;
    this.selStart = this.initialCaret;
    this.selEnd = this.initialCaret;
    setTimeout(() => {
      this.moveCaret(this.initialCaret);
    }, 0);
  }

  private focusNow(): void {
    try {
      this.getUIContext().getFocusController().requestFocus('whole-doc-editor');
    } catch (e) {
      // 聚焦失败不影响输入：点一下输入框照样能改。
    }
  }

  private moveCaret(pos: number): void {
    try {
      this.controller.caretPosition(pos < 0 ? 0 : pos);
    } catch (e) {
      // 定位失败就把光标留在原处，不影响内容。
    }
  }

  /** 格式按钮的结果：替换草稿、通知宿主、把光标放到应有位置。 */
  private applyResult(result: EditResult): void {
    this.draft = result.text;
    // 按钮改的是整段文本（长度差远不止 1），续写判定自然会跳过这一次；
    // 但仍要把基线跟上，免得编辑了一次前缀之后第一个回车被误判。
    this.prevDraft = result.text;
    this.onChange(result.text);
    setTimeout(() => {
      this.moveCaret(result.caret);
    }, 0);
  }

  /**
   * 回车续写：列表 / 待办 / 引用里敲回车，自动带上下一项的前缀。
   *
   * 只在「新旧文本只差一个换行」时生效（见 `MarkdownEdits.autoContinue`），
   * 所以粘贴、输入法组词、增删字符都会原样交给输入框。改完文本要**立刻**
   * 把光标放到新前缀之后，否则默认会停在续写出来的那一项的开头，下一个字会
   * 落在符号前面。
   */
  private onDraftEdited(value: string): void {
    const cont: EditResult | null = MarkdownEdits.autoContinue(this.prevDraft, value);
    if (cont !== null) {
      this.draft = cont.text;
      this.prevDraft = cont.text;
      this.onChange(cont.text);
      setTimeout(() => {
        this.moveCaret(cont.caret);
      }, 0);
      return;
    }
    this.draft = value;
    this.prevDraft = value;
    this.onChange(value);
  }

  build() {
    Column({ space: 8 }) {
      if (this.showFormatBar) {
        FormatBar({
          text: this.draft,
          selStart: this.selStart,
          selEnd: this.selEnd,
          onResult: (result: EditResult) => {
            this.applyResult(result);
          }
        })
      }

      TextArea({ text: $$this.draft, placeholder: '在这里写。', controller: this.controller })
        .id('whole-doc-editor')
        .width('100%')
        .layoutWeight(1)
        // 与正文**同一套排版**：同样的左右留白、同样的字体、同样的字号与行距。
        //
        // 之前这里是等宽字体 + 零内边距，点一下整页的字就「跳」过去换了一种气质，
        // 读起来像进了另一个应用。源码本来就不需要等宽——需要的是「这还是同一
        // 篇文章，只是符号露出来了」。
        .fontSize(this.bodySize)
        .lineHeight(this.bodySize * (this.lineHeight / 100))
        .fontColor($r('app.color.text_primary'))
        .placeholderColor($r('app.color.text_secondary'))
        .backgroundColor($r('app.color.page_bg'))
        .borderRadius(0)
        .padding({ left: 0, right: 0, top: 0, bottom: 0 })
        .onTextSelectionChange((start: number, end: number) => {
          this.selStart = start;
          this.selEnd = end;
        })
        .onChange((value: string) => {
          this.onDraftEdited(value);
        })
    }
    .width('100%')
    .layoutWeight(1)
    // 左右 20 vp 与渲染视图的 Scroll 内边距一致，切换时文字不会横向跳动。
    //
    // 顶部 64 vp 是为悬浮按钮让位：整篇输入时按钮仍然浮在上面（撤销 / AI 恰恰
    // 是写作时最需要的），第一行字不能落在它们底下。切换模式时这个值与渲染视图
    // 的 `CONTENT_TOP_INSET` 相同，两边的首行位置才不会一换模式就跳一下。
    .padding({ left: 20, right: 20, top: 64, bottom: 8 })
    .alignItems(HorizontalAlign.Start)
  }
}
