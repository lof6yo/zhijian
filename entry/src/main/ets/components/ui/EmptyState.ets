/**
 * 空状态。
 *
 * ## 三段式是既有范本，不是这里发明的
 *
 * `Index.ets` 的 `EmptyState()` 一开始就是这个形状：图标 48 / 0.6 透明度、
 * 标题 17 Medium、提示 13 居中。它成立的原因是**三段各答一个问题**——
 * 「这一片是什么」（图标）、「为什么是空的」（标题）、「那我该做什么」（提示）。
 * 少任何一段都会让用户停在原地：只有一行灰字时（标签页、回收站原来都是），
 * 人分不清这是「加载完了确实是空」还是「出错了没加载出来」。
 *
 * 所以这个组件不是「把三页的空态抄一致」，而是把那个已经想清楚的形状变成**唯一**
 * 的形状，让新页面没有机会发明第四种。
 *
 * ## `fill` 是布局档位，不是视觉风格
 *
 * `fill = true` 时 `layoutWeight(1)` 占满剩余空间、垂直居中，底部留 160 vp；
 * `fill = false` 只做内容宽居中，给 sheet / 卡片内部用。选错的后果是具体的：
 * 给 sheet 用 `true` 会把面板撑到全屏，给列表用 `false` 会让空态吊在顶部而下面
 * 一大片空白。
 *
 * 那 160 vp 同时服务两件事，所以比「页签栏高度 + 间距」大一点：
 *
 * - 没有键盘时避让悬浮页签栏（`barBottomMargin` 28 + `BAR_HEIGHT` 56）；
 * - **键盘在场时**搜索框展开、空态跟着视口一起缩短，块中心仍在可见区中央，而
 *   「没有匹配的笔记」那行提示的底沿正好落在键盘工具条上——实测被压掉约 6 px，
 *   读起来像提示被切了一半。多留 40 vp 把它抬离键盘。
 *
 * 这两种情况共用同一段留白是有意的：键盘在场时页签栏本来就不显示，两者不会叠加。
 */

@ComponentV2
export struct EmptyState {
  @Param icon: Resource = $r('sys.symbol.doc_text');
  @Param title: string = '';
  @Param hint: string = '';
  @Param fill: boolean = true;

  build() {
    Column({ space: 10 }) {
      SymbolGlyph(this.icon)
        .fontSize(48)
        .fontColor([$r('app.color.text_secondary')])
        .opacity(0.6)
      Text(this.title)
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .textAlign(TextAlign.Center)
      if (this.hint.length > 0) {
        Text(this.hint)
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .textAlign(TextAlign.Center)
          .constraintSize({ maxWidth: 320 })
      }
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ left: 24, right: 24, bottom: this.fill ? 160 : 0 })
    .layoutWeight(this.fill ? 1 : 0)
  }
}
