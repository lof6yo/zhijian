import { EditResult } from './MarkdownEdits';
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
    this.onChange(result.text);
    setTimeout(() => {
      this.moveCaret(result.caret);
    }, 0);
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
          this.draft = value;
          this.onChange(value);
        })
    }
    .width('100%')
    .layoutWeight(1)
    // 左右 20 vp 与渲染视图的 Scroll 内边距一致，切换时文字不会横向跳动。
    .padding({ left: 20, right: 20, top: 4, bottom: 8 })
    .alignItems(HorizontalAlign.Start)
  }
}
