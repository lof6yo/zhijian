import { MdBlock } from './MdTypes';
import { MdBlockView } from './MdView';
import { LiveBlockEditor } from './LiveBlockEditor';

/**
 * 文档视图：**永远是编辑态**，没有「只读 / 编辑」开关。
 *
 * ## 为什么取消模式
 *
 * 笔记应用的初衷是「打开就能记」。加一次「点编辑」的门，等于每次想改一个字都要
 * 先声明意图；而只读浏览本来就不该是一种需要切换的模式——Typora 那类工具里，
 * 正文一直可点，点哪行编哪行，其余仍是渲染结果。
 *
 * 所以这里只有一件事可变：**哪一块正在被编辑**。其余块保持渲染态，看上去就是
 * 一篇排好版的文章。
 *
 * ## 为什么不做整篇一个输入框
 *
 * 整篇可编辑意味着自建光标模型：跨块选区、撤销栈、输入法组词、粘贴时的结构
 * 推断。而 Markdown 的源码本身就是规范的一部分——用户写 `##`、`-`、`**`，
 * 这些符号一旦被藏起来，下一次输入会发生什么就不可预测。**点哪块、就地展开那块
 * 的源码、下面立刻显示它的渲染结果**，反馈闭环是完整的，但不需要第二套文档模型。
 *
 * ## 三个踩过的坑
 *
 * 1. 正文点击会被行内 `Span` 消费掉（每个 Span 都挂了 `onClick` 以便点链接），
 *    给自定义组件加 `.hitTestBehavior(HitTestMode.None)` 实测也不生效。唯一可靠
 *    的做法是把 `tapToEdit` 传进渲染层，让 `Span` 在自己的回调里分流。
 * 2. 不能用 `height('100%')` 的透明覆盖层接点击：百分比高度在内容驱动的父级里
 *    按**可用高度**解析，每块会被撑成一屏，后面的块全被顶出视口。
 * 3. 切换编辑块前必须先提交当前块，否则草稿丢失。
 */
@ComponentV2
export struct EditableDocument {
  @Param blocks: MdBlock[] = [];
  /** 正在编辑的块下标；-1 表示没有。 */
  @Param editingIndex: number = -1;
  /** 正在编辑的那一块的原始源码（只在 `editingIndex >= 0` 时有意义）。 */
  @Param editingSource: string = '';
  /** 追加新段落中：编辑框挂在文末。 */
  @Param appending: boolean = false;
  /**
   * 简单模式：**不**就地展开块编辑器。
   *
   * 被点中的块只上报一次点击，由宿主打开整篇输入框（并让光标落到这一块）。
   * 默认就是这条路——用户要的是记事本式的输入，而不是先理解「块」是什么。
   */
  @Param simpleMode: boolean = false;
  /** 格式按钮条（设置 › 格式按钮条）。 */
  @Param showFormatBar: boolean = false;
  /** 草稿的解析结果，供编辑态下方预览。 */
  @Param previewBlocks: MdBlock[] = [];
  @Param previewTick: number = 0;
  /**
   * 渲染纪元：正文每变一次 +1，并进 `ForEach` 的 key。
   *
   * `MdBlock.id` 是解析序号，勾选一个待办、改一个字的措辞都不会改变它——
   * key 不变时框架直接复用旧节点，界面就停在上一次的内容上（实测：文件已经写成
   * `- [x]`，屏幕上的圆圈还是空的）。所以内容的任何变化都必须让 key 跟着变。
   */
  @Param epoch: number = 0;

  @Param bodySize: number = 17;
  @Param lineHeight: number = 175;
  @Param dark: boolean = false;
  @Param accentColor: string = '#0A59F7';

  @Event onBlockTap: (index: number) => void = () => {};
  @Event onDraftChange: (value: string) => void = () => {};
  @Event onCommit: () => void = () => {};
  @Event onDelete: () => void = () => {};
  @Event onTaskToggle: (block: MdBlock) => void = () => {};
  @Event onAddBlock: () => void = () => {};

  build() {
    Column({ space: 2 }) {
      ForEach(this.blocks, (block: MdBlock, index: number) => {
        if (!this.simpleMode && index === this.editingIndex && !this.appending) {
          LiveBlockEditor({
            block: block,
            index: index,
            initialSource: this.editingSource,
            previewBlocks: this.previewBlocks,
            previewTick: this.previewTick,
            bodySize: this.bodySize,
            lineHeight: this.lineHeight,
            dark: this.dark,
            accentColor: this.accentColor,
            showFormatBar: this.showFormatBar,
            onDraftChange: (value: string) => {
              this.onDraftChange(value);
            },
            onCommit: () => {
              this.onCommit();
            },
            onDelete: () => {
              this.onDelete();
            }
          })
        } else {
          Stack({ alignContent: Alignment.TopStart }) {
            MdBlockView({
              block: block,
              bodySize: this.bodySize,
              lineHeight: this.lineHeight,
              dark: this.dark,
              accentColor: this.accentColor,
              // 让正文片段把点击回传上来；没有 Span 的区域（代码块、表格、
              // 分割线）由这一层自己接。
              tapToEdit: true,
              onBlockTap: () => {
                this.onBlockTap(index);
              },
              // 任务勾选在渲染态就能点：勾一下是「结清一件事」，不该要求先进编辑。
              onTaskToggle: (item: MdBlock) => {
                this.onTaskToggle(item);
              }
            })
          }
          .width('100%')
          .padding({ top: 2, bottom: 2 })
          .onClick(() => {
            this.onBlockTap(index);
          })
          .clickEffect({ level: ClickEffectLevel.LIGHT })
          .accessibilityText('点按编辑这一块')
        }
      }, (block: MdBlock, index: number) => `${block.id}-${this.epoch}-${index === this.editingIndex && !this.appending ? 'e' : 'r'}`)

      if (this.appending && !this.simpleMode) {
        LiveBlockEditor({
          block: this.blocks.length > 0 ? this.blocks[this.blocks.length - 1] : this.blocks[0],
          index: this.blocks.length,
          appendMode: true,
          initialSource: '',
          previewBlocks: this.previewBlocks,
          previewTick: this.previewTick,
          bodySize: this.bodySize,
          lineHeight: this.lineHeight,
          dark: this.dark,
          accentColor: this.accentColor,
          showFormatBar: this.showFormatBar,
          onDraftChange: (value: string) => {
            this.onDraftChange(value);
          },
          onCommit: () => {
            this.onCommit();
          },
          onDelete: () => {
            this.onDelete();
          }
        })
      } else if (!this.simpleMode && this.editingIndex < 0) {
        // 文末的追加入口。没有它，「在末尾再写一段」就得去改最后一块——
        // 那不是一个「打开就能记」的应用该让人琢磨的事。
        Row({ space: 6 }) {
          Text('+')
            .fontSize(15)
            .fontColor(this.accentColor)
          Text('继续写')
            .fontSize(13)
            .fontColor(this.accentColor)
        }
        .padding({ left: 4, right: 12, top: 10, bottom: 10 })
        .borderRadius(10)
        .onClick(() => {
          this.onAddBlock();
        })
        .accessibilityText('在末尾添加一段')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
