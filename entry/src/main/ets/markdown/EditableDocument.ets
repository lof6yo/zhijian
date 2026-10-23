import { MdBlock } from './MdTypes';
import { MdBlockView } from './MdView';
import { LiveBlockEditor } from './LiveBlockEditor';

/**
 * 实时预览模式的文档视图：一次 `ForEach` 遍历所有块，被点中的那一块就地
 * 换成 `LiveBlockEditor`，其余保持渲染态。
 *
 * ## 为什么不做「整篇一个 TextArea 的预览/源码分栏」
 *
 * 分栏模式要求用户自己在脑子里把「我改的第 37 行」对应到「右边的第 12 段」，
 * 而且长文里左右两侧的滚动位置永远对不齐。**就地展开**把这种对应关系消掉了：
 * 你点哪一块就改哪一块，改的就是眼前这一段。
 *
 * ## 为什么不复用 `MdDocumentView`
 *
 * `MdDocumentView` 是只读的（这是它该有的职责）。编辑态需要多两件东西：每块的
 * 点击回调、以及「哪一块正在编辑」这个位置。把这两件事塞进只读组件，会让它既
 * 管排版又管编辑状态；这里用一个独立的容器把它们分开，`MdBlockView` 本身仍然
 * 只负责画一个块。
 */
@ComponentV2
export struct EditableDocument {
  @Param blocks: MdBlock[] = [];
  /** 正在编辑的块下标；-1 表示没有。 */
  @Param editingIndex: number = -1;
  /** 正在编辑的那一块的原始源码（只在 `editingIndex >= 0` 时有意义）。 */
  @Param editingSource: string = '';
  /** 草稿的解析结果，供编辑态下方预览。 */
  @Param previewBlocks: MdBlock[] = [];
  @Param previewTick: number = 0;

  @Param bodySize: number = 17;
  @Param lineHeight: number = 175;
  @Param dark: boolean = false;
  @Param accentColor: string = '#0A59F7';

  @Event onBlockTap: (index: number) => void = () => {};
  @Event onDraftChange: (value: string) => void = () => {};
  @Event onCommit: () => void = () => {};
  @Event onDelete: () => void = () => {};

  build() {
    Column({ space: 2 }) {
      ForEach(this.blocks, (block: MdBlock, index: number) => {
        if (index === this.editingIndex) {
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
          // 整块可点，且不能靠「盖一层透明层」——`height('100%')` 在高度由内容
          // 决定的父级里会按**可用高度**解析，于是每一块都被撑成一屏高，后面的
          // 块被顶出视口（实测只剩两块可见）。
          //
          // 真正的问题是正文行内每个 `Span` 都带 `onClick`（链接要能点），点击
          // 会被它消费掉，外层收不到。所以这里反其道：**让渲染子树不参与命中**，
          // 由外层 `Stack` 自己接点击。副作用是编辑态里链接不可点——这是对的，
          // 在编辑态点一块的意图是「改它」，不是「打开它」。
          Stack({ alignContent: Alignment.TopStart }) {
            MdBlockView({
              block: block,
              bodySize: this.bodySize,
              lineHeight: this.lineHeight,
              dark: this.dark,
              accentColor: this.accentColor,
              // 让正文片段自己把点击回传上来。覆盖层和 hitTestBehavior 都不行：
              // Span 上的 onClick 会先消费掉事件，而自定义组件不接受命中策略。
              tapToEdit: true,
              onBlockTap: () => {
                this.onBlockTap(index);
              }
            })
          }
          .width('100%')
          .padding({ top: 2, bottom: 2 })
          // 没有 Span 的区域（代码块、表格、分割线）仍然由这一层接点击。
          .onClick(() => {
            this.onBlockTap(index);
          })
          .accessibilityText('编辑这一块')
        }
      }, (block: MdBlock, index: number) => `${block.id}-${index === this.editingIndex ? 'e' : 'r'}`)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
