/**
 * NavDestination 页头。
 *
 * ## 它替掉了什么
 *
 * 回收站和 WebDAV 两页各写了一遍同样的页头，而且两遍**不一样**：
 *
 * | | `TrashPage` | `WebDavPage` |
 * |---|---|---|
 * | 返回 | `Button('‹')` 28 fp | `Button('‹')` 28 fp |
 * | 标题 | 24 **Bold** | 16 Medium |
 * | 副标题 | 12 | 11 |
 *
 * `Button('‹')` 是一个**文本字符**，不是图标：它的字形、基线、左右留白都来自字体，
 * 换个字号就换一个视觉中心，28 fp 的那个撇甚至顶不到 44 vp 热区的正中。标题那栏
 * 更明显——24 Bold 在深色模式下比系统弹窗还响，而它只是应用内的一个页面标题。
 *
 * 所以这里只有一种页头：**56 vp 一行、SymbolGlyph 返回、16 Medium 标题**。
 * 副标题和尾部动作都是可选的，这样「有副标题的页」和「没有的页」不会因为高度不同
 * 而让内容起点错开一档。
 *
 * ## 为什么没有 top padding
 *
 * `NavDestination` 的内容原点**已经在状态栏下方**，这里再加一个 `padding({top: 40})`
 * 只会把页头压低 40 vp，读起来像「下沉过多」。这个坑在 `EditorPage` 和 `TrashPage`
 * 上各踩过一次（见 AGENTS.md §6）。
 *
 * ## 尾部动作为什么要 `danger`
 *
 * 回收站的「清空」是不可逆操作。原来它是 13 fp 的危险色文字，与「恢复」的 12 fp
 * 强调色文字同排却不同档——两个动作一个是行内小按钮、一个是页头动作，尺寸不该靠
 * 各自随手写。这里固定成 12 fp，`danger` 只换颜色、不换尺寸。
 */

import { RADIUS_PILL, FONT_PAGE_TITLE, FONT_MICRO, FONT_SECONDARY } from '../../common/UiTokens';

@ComponentV2
export struct PageHeader {
  @Param title: string = '';
  @Param subtitle: string = '';
  /** 尾部文字动作（回收站的「清空」）。空字符串表示没有。 */
  @Param trailing: string = '';
  /** 尾部动作染危险色。 */
  @Param trailingDanger: boolean = false;
  /** 尾部的**非动作**文本（WebDAV 的 `zhijian/`）。与 `trailing` 互斥，优先 `trailing`。 */
  @Param note: string = '';
  @Event onBack: () => void = () => {};
  @Event onTrailing: () => void = () => {};

  build() {
    Row({ space: 8 }) {
      // 返回：44×44 的透明热区 + 图标。用 SymbolGlyph 而不是 `Button('‹')`——
      // 图标本身居中、不随字体基线漂移，热区尺寸也可以和标题的字号无关。
      Stack({ alignContent: Alignment.Center }) {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(22)
          .fontColor([$r('app.color.text_primary')])
      }
      .width(44)
      .height(44)
      .borderRadius(RADIUS_PILL)
      .onClick(() => {
        this.onBack();
      })
      .accessibilityText('返回')

      Column({ space: 2 }) {
        Text(this.title)
          .fontSize(FONT_PAGE_TITLE)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.subtitle.length > 0) {
          Text(this.subtitle)
            .fontSize(FONT_MICRO)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (this.trailing.length > 0) {
        Text(this.trailing)
          .fontSize(FONT_SECONDARY)
          .fontColor(this.trailingDanger ? $r('app.color.danger') : $r('app.color.text_secondary'))
          .padding({ left: 10, right: 2, top: 6, bottom: 6 })
          .onClick(() => {
            this.onTrailing();
          })
          .accessibilityText(this.trailing)
      } else if (this.note.length > 0) {
        Text(this.note)
          .fontSize(FONT_MICRO)
          .fontColor($r('app.color.text_secondary'))
      }
    }
    .width('100%')
    .height(56)
    .padding({ left: 8, right: 16 })
    .backgroundColor($r('app.color.page_bg'))
  }
}
