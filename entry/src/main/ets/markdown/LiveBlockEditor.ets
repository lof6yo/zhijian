import { MdBlock, emptyBlock } from './MdTypes';
import { MdBlockView } from './MdView';

/**
 * 实时预览编辑的「块编辑态」。
 *
 * ## 为什么是「上面改源码、下面看渲染」
 *
 * 真正所见即所得的富文本编辑器要自建光标模型：选区跨块、撤销栈、输入法组词、
 * 粘贴时的结构推断……那是一整个编辑器内核。而 Markdown 的**源码本身就是
 * 规范的一部分**——用户写的是 `##`、`-`、`**`，这些东西一旦被藏起来，用户就
 * 无法预测下一次输入会发生什么。
 *
 * 所以这里的选择是：**就地展开该块的原文，下面立刻显示它渲染出来的样子**。
 * 改一个 `#` 马上看到标题出现，改一个 `**` 马上看到加粗——反馈闭环是完整的，
 * 但不需要发明第二套文档模型。
 *
 * ## 三条边界（照抄了参考实现的结论，都是踩出来的）
 *
 * 1. **组件，不是 `@Builder`。** 在 `ForEach` 的 itemGenerator 里调 `@Builder`
 *    在本工程有过白屏先例；`ForEach` 里放自定义组件是安全的。
 * 2. **组件不碰原文。** 它只持有草稿并回调，写回由宿主按块的行区间完成——
 *    这样「这一块改错了」不会污染别处。
 * 3. **预览解析的是草稿本身**（宿主解析好传进来），所以代码块/公式在编辑态里
 *    就是它最终的样子。
 */
@ComponentV2
export struct LiveBlockEditor {
  /** 正在编辑的块（渲染态的版本，只用来看类型与展示标签）。 */
  @Param block: MdBlock = emptyBlock();
  /** 该块在正文里的下标；写回与删除都要带回去。 */
  @Param index: number = -1;
  /** 草稿的解析结果，由宿主在草稿变化时解析好传进来。 */
  @Param previewBlocks: MdBlock[] = [];
  /**
   * 预览刷新计数。
   *
   * 块 id 是解析序号，打字时不变；不把它并进 `ForEach` 的 key，框架就会复用
   * 旧节点，预览看起来「不刷新」。宿主每次重解析都要 +1。
   */
  @Param previewTick: number = 0;
  @Param bodySize: number = 17;
  @Param lineHeight: number = 175;
  @Param dark: boolean = false;
  @Param accentColor: string = '#0A59F7';

  /** 草稿。组件自己持有，变化时向上回调。 */
  @Local draft: string = '';

  @Event onDraftChange: (value: string) => void = () => {};
  @Event onCommit: () => void = () => {};
  @Event onDelete: () => void = () => {};

  aboutToAppear(): void {
    this.draft = this.initialSource;
    this.focusNow();
    // 焦点必须**挤进一帧之内**交接。
    //
    // 从一块切到另一块时，旧编辑组件被移除、新的才挂载；中间空档一长，系统会
    // 先把输入法收起、等新组件上树再弹出来，观感就是键盘闪一下。多次短间隔
    // 重试覆盖「组件刚挂载但还没真正上树」的窗口。
    setTimeout(() => {
      this.focusNow();
    }, 8);
    setTimeout(() => {
      this.focusNow();
    }, 32);
    setTimeout(() => {
      this.focusNow();
    }, 90);
  }

  /**
   * 宿主传入的初始源码。
   *
   * 用 `@Param` 而不是 `@Link`：`@Link` 要求宿主与被编辑组件共享同一个可变引用，
   * 而宿主那一侧还要做行区间拼装，共享引用只会让「草稿」和「原文」两个概念混在
   * 一起。单向传入 + 事件回传，边界清楚。
   */
  @Param initialSource: string = '';

  /**
   * 输入框 id 必须**带块下标**。
   *
   * 共用一个固定 id 时，切换块的那一帧里新旧实例并存，`requestFocus` 很可能命中
   * 正在销毁的旧节点，聚焦落空、键盘收起。带下标后每次精确指向新实例。
   */
  private focusId(): string {
    return 'live-block-editor-' + this.index;
  }

  private focusNow(): void {
    try {
      this.getUIContext().getFocusController().requestFocus(this.focusId());
    } catch (e) {
      // 聚焦失败不影响输入：点一下输入框照样能改。
    }
  }

  /** 块类型标签，让用户知道自己在改什么。 */
  private kindLabel(): string {
    switch (this.block.kind) {
      case 0:
        return '标题';
      case 2:
        return '代码';
      case 4:
        return '列表项';
      case 5:
        return '表格';
      case 6:
        return '分割线';
      case 3:
        return '引用';
      case 7:
        return '提示块';
      case 8:
        return '公式';
      case 9:
        return '图表';
      default:
        return '段落';
    }
  }

  build() {
    Column({ space: 8 }) {
      // 头部：正在编辑 · 类型 ＋ 删除 / 完成。
      // 「完成」是实心高亮，让「改完点哪儿」一眼可见。
      Row({ space: 6 }) {
        Row({ space: 5 }) {
          Column()
            .width(3)
            .height(13)
            .borderRadius(2)
            .backgroundColor(this.accentColor)
          Text(`正在编辑 · ${this.kindLabel()}`)
            .fontSize(11)
            .fontColor(this.accentColor)
        }
        .alignItems(VerticalAlign.Center)

        Blank()

        Text('删除')
          .fontSize(12)
          .fontColor($r('app.color.danger'))
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .borderRadius(12)
          .backgroundColor($r('app.color.page_bg'))
          .onClick(() => {
            this.onDelete();
          })
          .accessibilityText('删除这一块')

        Text('完成')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.on_accent'))
          .padding({ left: 12, right: 12, top: 5, bottom: 5 })
          .borderRadius(12)
          .backgroundColor(this.accentColor)
          .onClick(() => {
            this.onCommit();
          })
          .accessibilityText('完成这一块的编辑')
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 输入区。给足底色与描边，一眼看出「这里可以打字」——
      // 无底色无边框的一行字与正文长得差不多，用户不知道点进来了。
      TextArea({ text: this.draft, placeholder: '在这里改这一块的 Markdown 源码……' })
        .id(this.focusId())
        .width('100%')
        // 不设死高度：由内容撑开，避免编辑区自己长出第二个滚动条。
        .constraintSize({ minHeight: 56 })
        .fontSize(this.bodySize * 0.92)
        .fontFamily('monospace')
        .fontColor($r('app.color.text_primary'))
        .placeholderColor($r('app.color.text_secondary'))
        .backgroundColor($r('app.color.md_code_surface'))
        .borderRadius(10)
        .border({ width: 1, color: $r('app.color.md_math_border') })
        .padding({ left: 10, right: 10, top: 6, bottom: 6 })
        .onChange((value: string) => {
          this.draft = value;
          this.onDraftChange(value);
        })

      if (this.previewBlocks.length > 0) {
        Column() {
          Row() {
            Text('预览效果')
              .fontSize(11)
              .fontColor($r('app.color.text_secondary'))
            Blank()
            Text('以正文样式渲染')
              .fontSize(10)
              .fontColor($r('app.color.text_secondary'))
              .opacity(0.7)
          }
          .width('100%')
          .padding({ bottom: 4 })

          ForEach(this.previewBlocks, (pb: MdBlock) => {
            MdBlockView({
              block: pb,
              bodySize: this.bodySize,
              lineHeight: this.lineHeight,
              dark: this.dark,
              accentColor: this.accentColor
            })
          }, (pb: MdBlock) => `lbe-${pb.id}-${this.previewTick}`)
        }
        .width('100%')
        .padding({ top: 6 })
        // 虚线分隔：明确「上面是源码、下面是效果」。
        .border({ width: { top: 1 }, color: $r('app.color.divider'), style: BorderStyle.Dashed })
      }
    }
    .width('100%')
    .padding({ top: 8, bottom: 12 })
    .alignItems(HorizontalAlign.Start)
  }
}
