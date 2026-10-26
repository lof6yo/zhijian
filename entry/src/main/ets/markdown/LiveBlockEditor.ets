import { MdBlock, emptyBlock } from './MdTypes';
import { MdBlockView, listNumberAt, tightTopAt } from './MdView';
import { EditResult } from './MarkdownEdits';
import { FormatBar } from './FormatBar';

/**
 * 分块编辑：只改被点中的那一块，上面是它的源码，下面是它的渲染结果。
 *
 * ## 这是可选的高级模式
 *
 * 默认关闭（设置 › 分块编辑）。绝大多数时候用户只想改一句话，整篇输入框就够了；
 * 分块编辑的价值在长文档里——改表格、改代码块、改公式时，能立刻看到这一块渲染成
 * 什么样。开启后它才替换掉整篇输入。
 *
 * ## 为什么是源码而不是富文本光标
 *
 * Markdown 的源码本身就是规范的一部分。把 `##`、`-`、`**` 藏进一个内部模型，
 * 用户就无法预判再敲一个字符会发生什么。源码在上、渲染在下，反馈闭环完整，
 * 而代价只是「看得见符号」。
 *
 * ## 三条踩过的边界
 *
 * 1. **组件，不是 `@Builder`。** `ForEach` 的 itemGenerator 里调 `@Builder`
 *    本工程有过白屏先例。
 * 2. **组件不碰原文。** 只持有草稿并回调，写回由宿主按行区间完成。
 * 3. **切换块时组件实例会被复用**，所以草稿必须靠 `@Monitor('initialSource')`
 *    重新播种，不能只在 `aboutToAppear` 里赋值。
 */
@ComponentV2
export struct LiveBlockEditor {
  @Param block: MdBlock = emptyBlock();
  @Param index: number = -1;
  @Param previewBlocks: MdBlock[] = [];
  /**
   * 预览刷新计数。块 id 是解析序号、打字时不变，不并进 `ForEach` 的 key 就会
   * 复用旧节点，预览看起来「不刷新」。
   */
  @Param previewTick: number = 0;
  @Param bodySize: number = 17;
  @Param lineHeight: number = 175;
  @Param dark: boolean = false;
  @Param accentColor: string = '#0A59F7';
  @Param initialSource: string = '';
  /** 追加新段落时标签显示「新段落」。 */
  @Param appendMode: boolean = false;
  /** 格式按钮条（设置 › 格式按钮条，默认关）。 */
  @Param showFormatBar: boolean = false;

  @Local draft: string = '';
  @Local selStart: number = 0;
  @Local selEnd: number = 0;
  @Local seeded: string = '';

  @Event onDraftChange: (value: string) => void = () => {};
  @Event onCommit: () => void = () => {};
  @Event onDelete: () => void = () => {};

  private controller: TextAreaController = new TextAreaController();

  aboutToAppear(): void {
    this.seed();
    this.focusNow();
    // 焦点要挤进一帧之内交接：空档一长，系统会先收起输入法再弹出来。
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
   * `initialSource` 变化时重新播种。
   *
   * 从「编辑某一块」切到「文末追加」会**复用同一个组件实例**（结构位置没变），
   * `aboutToAppear` 不会再跑，输入框会留着上一块的源码——用户以为在写新段落，
   * 实际在改上一段。
   */
  @Monitor('initialSource')
  onSourceChange(monitor: IMonitor): void {
    this.seed();
    this.focusNow();
  }

  private seed(): void {
    if (this.seeded === this.initialSource) {
      return;
    }
    this.seeded = this.initialSource;
    this.draft = this.initialSource;
    this.selStart = this.initialSource.length;
    this.selEnd = this.initialSource.length;
  }

  /** 输入框 id 带块下标：共用固定 id 时切块会命中正在销毁的旧节点。 */
  private focusId(): string {
    return 'live-block-editor-' + this.index;
  }

  private focusNow(): void {
    try {
      this.getUIContext().getFocusController().requestFocus(this.focusId());
    } catch (e) {
      // 聚焦失败不影响输入。
    }
  }

  private applyResult(result: EditResult): void {
    this.draft = result.text;
    this.onDraftChange(result.text);
    setTimeout(() => {
      try {
        this.controller.caretPosition(result.caret);
      } catch (e) {
        // 定位失败不影响内容。
      }
    }, 0);
  }

  private kindLabel(): string {
    if (this.appendMode) {
      return '新段落';
    }
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
      default:
        return '段落';
    }
  }

  build() {
    Column({ space: 8 }) {
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

      TextArea({ text: $$this.draft, placeholder: '在这里改这一块。', controller: this.controller })
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
        .onTextSelectionChange((start: number, end: number) => {
          this.selStart = start;
          this.selEnd = end;
        })
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

          ForEach(this.previewBlocks, (pb: MdBlock, index: number) => {
            MdBlockView({
              block: pb,
              bodySize: this.bodySize,
              lineHeight: this.lineHeight,
              dark: this.dark,
              accentColor: this.accentColor,
              // 预览也是正文：序号与紧贴关系要和阅读态一致，否则预览里一条列表
              // 会带着一整段间距，看起来和提交后的排版不是同一份文档。
              listNumber: listNumberAt(this.previewBlocks, index, pb),
              tightTop: tightTopAt(this.previewBlocks, index, pb)
            })
          }, (pb: MdBlock) => `lbe-${pb.id}-${this.previewTick}`)
        }
        .width('100%')
        .padding({ top: 6 })
        .border({ width: { top: 1 }, color: $r('app.color.divider'), style: BorderStyle.Dashed })
      }
    }
    .width('100%')
    .padding({ top: 8, bottom: 12 })
    .alignItems(HorizontalAlign.Start)
  }
}
