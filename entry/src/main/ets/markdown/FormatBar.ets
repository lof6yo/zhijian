import { MarkdownEdits, EditResult } from './MarkdownEdits';

/**
 * 格式按钮条。**默认不出现在界面上**（设置 › 格式按钮条）。
 *
 * 它存在的唯一理由是：不熟悉 Markdown 的人只会写纯文字，需要有一颗按钮把
 * 「标题」「列表」「待办」变成可点出来的东西。但它同时是一种干扰——只想改一句话
 * 的人不该先看到一排按钮。所以默认关闭，需要的人在设置里打开。
 *
 * 按钮只发语义 id，具体改动由 `MarkdownEdits` 决定：这样整篇输入和分块编辑
 * 共用同一套规则，不会出现「同一颗按钮在两种模式下结果不同」。
 */
@ComponentV2
export struct FormatBar {
  /** 当前文本与选区，由宿主提供。 */
  @Param text: string = '';
  @Param selStart: number = 0;
  @Param selEnd: number = 0;

  @Event onResult: (result: EditResult) => void = () => {};

  private pick(action: string): void {
    this.onResult(MarkdownEdits.apply(this.text, this.selStart, this.selEnd, action));
  }

  @Builder
  Chip(label: string, action: string) {
    Text(label)
      .fontSize(12)
      .fontColor($r('app.color.text_primary'))
      .padding({ left: 10, right: 10, top: 6, bottom: 6 })
      .borderRadius(9)
      .backgroundColor($r('app.color.chip_bg'))
      .onClick(() => {
        this.pick(action);
      })
      .accessibilityText(label)
  }

  build() {
    Scroll() {
      Row({ space: 6 }) {
        this.Chip('标题', 'heading')
        this.Chip('粗体', 'bold')
        this.Chip('斜体', 'italic')
        this.Chip('列表', 'list')
        this.Chip('待办', 'todo')
        this.Chip('引用', 'quote')
        this.Chip('表格', 'table')
        this.Chip('代码', 'code')
      }
      .padding({ right: 4 })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .align(Alignment.Start)
  }
}
