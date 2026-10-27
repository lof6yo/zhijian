/**
 * 纸见 · Markdown 原生 ArkUI 渲染器
 *
 * 设计目标：阅读页要像一本排印精良的书。节奏、留白、字号层级是核心；
 * 只有代码块、表格和占位卡片使用重表面。
 *
 * 实现约束（来自 docs/markdown-engine.md）：
 * - 块级是扁平数组，没有递归组件。
 * - 行内富文本必须是 `Text() { ForEach(...) { Span(...) } }`；
 *   ForEach 分支里嵌套 Text 会破坏父级样式追踪。
 */

import { LengthMetrics } from '@kit.ArkUI';
import {
  MdBlock,
  MdBlockKind,
  MdCalloutKind,
  MdInline,
  MdInlineKind,
  MdTableRow,
  MdTaskState,
  emptyBlock
} from './MdTypes';
import { CodeHighlight, CodeToken, CodeTokenStyle } from './CodeHighlight';
import { FormulaWeb } from '../components/FormulaWeb';
import { MathLite } from './MathLite';

// ===== 节奏标尺（全部来自这里，避免随处硬编码） =====
const SPACE_BLOCK = 16;        // 块之间基准间距
const SPACE_TIGHT = 8;         // 紧凑间距（卡片内、任务列表等）
const SPACE_HEAD_ABOVE_H1 = 28;
const SPACE_HEAD_ABOVE_H2 = 24;
const SPACE_HEAD_ABOVE_H3 = 22;
const SPACE_HEAD_ABOVE_H4 = 20;
const SPACE_HEAD_ABOVE_H5 = 18;
const SPACE_HEAD_ABOVE_H6 = 18;
const SPACE_HEAD_BELOW_H1 = 10;
const SPACE_HEAD_BELOW_H2 = 8;
const SPACE_HEAD_BELOW_H3_H6 = 8;
const LIST_INDENT = 20;        // 列表每级缩进
const SPACE_LIST_TIGHT = 2;    // 相邻列表项之间的间距（它们是一条条，不是一个段落）
const QUOTE_BAR_WIDTH = 3;     // 引用竖条宽度
const QUOTE_DEPTH_INSET = 8;   // 引用每层额外缩进
const CODE_RADIUS = 12;
const CODE_PAD = 12;
const CODE_LINE_HEIGHT = 1.6;  // 代码行行高系数
const TABLE_CELL_MIN_W = 80;   // 表格单元格最小宽度
const TASK_HIT = 24;           // 任务复选框点击区域

// ===== 文档视图 =====

@ComponentV2
export struct MdDocumentView {
  @Param blocks: MdBlock[] = [];
  @Param bodySize: number = 17;        // 正文字号
  @Param lineHeight: number = 175;     // 行高百分比，175 = 1.75
  @Param dark: boolean = false;
  @Param accentColor: string = '#0A59F7';
  @Param onLink: (href: string) => void = () => {};
  @Param onTaskToggle: (block: MdBlock) => void = () => {};

  build() {
    Column({ space: 0 }) {
      ForEach(this.blocks, (block: MdBlock, index: number) => {
        MdBlockView({
          block: block,
          bodySize: this.bodySize,
          lineHeight: this.lineHeight,
          dark: this.dark,
          accentColor: this.accentColor,
          onLink: this.onLink,
          onTaskToggle: this.onTaskToggle,
          listNumber: this.computeListNumber(index, block),
          tightTop: this.isTightTop(index, block)
        })
      }, (block: MdBlock) => block.id)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  private computeListNumber(index: number, block: MdBlock): number {
    return listNumberAt(this.blocks, index, block);
  }

  private isTightTop(index: number, block: MdBlock): boolean {
    return tightTopAt(this.blocks, index, block);
  }
}

/**
 * 第几号有序列表项（`1.` / `2.` …），非有序项或非列表项返回 0。
 *
 * 抽成模块级函数而不是 `MdDocumentView` 的私有方法：**渲染列表项的每个宿主都要
 * 算出同一个号**。之前只有 `MdDocumentView` 算，而笔记页真正渲染正文的是
 * `EditableDocument`——它直接调 `MdBlockView` 且不传 `listNumber`，于是阅读页里
 * 所有有序列表都显示成 `0.`。一个必须两处都用的规则不能只写在一处。
 */
export function listNumberAt(blocks: MdBlock[], index: number, block: MdBlock): number {
  if (block.kind !== MdBlockKind.ListItem || !block.ordered) {
    return 0;
  }
  let consecutive: number = 0;
  for (let i: number = index; i >= 0; i--) {
    const b: MdBlock = blocks[i];
    if (b.kind === MdBlockKind.ListItem && b.ordered && b.indent === block.indent) {
      consecutive++;
    } else {
      break;
    }
  }
  return block.seq + consecutive - 1;
}

/**
 * 这一块是否紧贴着上一块（两个相邻列表项之间不该再走一个 16 vp 的段间距）。
 *
 * 同样是每个宿主都要算的规则，理由与 `listNumberAt` 一致：`EditableDocument`
 * 漏传它，阅读页里的列表就一项一段、行距看起来大得离谱——用户报的「列表行距
 * 过大」正是这个默认值，不是字体行高。
 */
export function tightTopAt(blocks: MdBlock[], index: number, block: MdBlock): boolean {
  if (index === 0) {
    return false;
  }
  const prev: MdBlock = blocks[index - 1];
  return block.kind === MdBlockKind.ListItem && prev.kind === MdBlockKind.ListItem;
}

// ===== 单块视图（笔记列表等可复用） =====

@ComponentV2
export struct MdBlockView {
  @Param block: MdBlock = emptyBlock();
  @Param bodySize: number = 17;
  @Param lineHeight: number = 175;
  @Param dark: boolean = false;
  @Param accentColor: string = '#0A59F7';
  @Param onLink: (href: string) => void = () => {};
  @Param onTaskToggle: (block: MdBlock) => void = () => {};
  // 以下两项由 MdDocumentView 计算后传入；外部单块复用时保持默认值即可。
  @Param listNumber: number = 0;
  @Param tightTop: boolean = false;
  /**
   * 编辑态：正文里的点击不再当链接处理，而是回传「这一块被点了」。
   *
   * 必须做成一个开关而不是给外层加覆盖层：行内每个 `Span` 都带 `onClick`
   * （链接要能点），点击会被 `Span` 消费掉，外层容器根本收不到。实测给自定义
   * 组件加 `.hitTestBehavior(HitTestMode.None)` 也不生效。唯一可靠的办法就是
   * 在 `Span` 自己的回调里分流。
   */
  @Param tapToEdit: boolean = false;
  @Event onBlockTap: () => void = () => {};

  build() {
    if (this.block.kind === MdBlockKind.Heading) {
      this.HeadingBlock();
    } else if (this.block.kind === MdBlockKind.Paragraph) {
      this.ParagraphBlock();
    } else if (this.block.kind === MdBlockKind.Code) {
      this.CodeBlock();
    } else if (this.block.kind === MdBlockKind.Quote) {
      this.QuoteBlock();
    } else if (this.block.kind === MdBlockKind.ListItem) {
      this.ListItemBlock();
    } else if (this.block.kind === MdBlockKind.Table) {
      this.TableBlock();
    } else if (this.block.kind === MdBlockKind.Divider) {
      this.DividerBlock();
    } else if (this.block.kind === MdBlockKind.Callout) {
      this.CalloutBlock();
    } else if (this.block.kind === MdBlockKind.Math) {
      this.MathBlock();
    } else {
      this.ParagraphBlock();
    }
  }

  // ===== 标题 =====

  @Builder
  HeadingBlock() {
    Column({ space: 0 }) {
      MdInlineText({
        inlines: this.block.inlines,
        bodySize: this.bodySize,
        lineHeight: this.lineHeight,
        dark: this.dark,
        accentColor: this.accentColor,
        onLink: this.onLink,
        tapToEdit: this.tapToEdit,
        onTextTap: this.onBlockTap,
        overrideSize: this.headingSize(this.block.level),
        overrideWeight: this.headingWeight(this.block.level),
        overrideColor: this.block.level >= 6 ? $r('app.color.text_secondary') : $r('app.color.text_primary')
      })
        .width('100%')

      if (this.block.level <= 2) {
        Row()
          .width('100%')
          .height(1)
          .backgroundColor($r('app.color.divider'))
          .margin({ top: this.headingBottomSpace(this.block.level) })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({
      top: this.tightTop ? SPACE_TIGHT : this.headingTopSpace(this.block.level),
      bottom: this.block.level <= 2 ? 0 : this.headingBottomSpace(this.block.level)
    })
  }

  // ===== 段落 =====

  @Builder
  ParagraphBlock() {
    MdInlineText({
      inlines: this.block.inlines,
      bodySize: this.bodySize,
      lineHeight: this.lineHeight,
      dark: this.dark,
      accentColor: this.accentColor,
      onLink: this.onLink,
      tapToEdit: this.tapToEdit,
      onTextTap: this.onBlockTap
    })
      .width('100%')
      .margin({ top: this.tightTop ? SPACE_TIGHT : SPACE_BLOCK })
  }

  // ===== 代码块 =====

  @Builder
  CodeBlock() {
    Column({ space: 0 }) {
      if (this.block.lang.length > 0) {
        Text(this.block.lang)
          .fontSize(this.bodySize * 0.75)
          .fontColor($r('app.color.text_secondary'))
          .position({ top: 8, right: 12 })
      }

      Scroll() {
        Column({ space: 0 }) {
          ForEach(this.tokenizedLines(), (line: CodeToken[], index: number) => {
            Text() {
              ForEach(line, (token: CodeToken, t: number) => {
                Span(token.text)
                  .fontColor(this.tokenColor(token.style))
              }, (token: CodeToken, t: number) => `${token.text}-${t}`)
            }
            .fontFamily('monospace')
            .fontSize(this.bodySize * 0.85)
            .fontColor($r('app.color.md_code_plain'))
            .lineHeight(this.bodySize * CODE_LINE_HEIGHT)
            .height(this.bodySize * CODE_LINE_HEIGHT)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Clip })
            .width('100%')
            // 代码也要能复制：一条 `npm i` 抄不出来就得手打。
            // 代码块的外层 `Scroll` 与逐行的 `Span` 都不消费长按，所以这里加
            // 选择不会和任何「点一下进编辑」抢事件——那一层在 `EditableDocument`
            // 的容器上。
            .copyOption(CopyOptions.LocalDevice)
            .textSelectable(TextSelectableMode.SELECTABLE_UNFOCUSABLE)
          }, (line: CodeToken[], index: number) => `${index}`)
        }
        .width('auto')
        .alignItems(HorizontalAlign.Start)
        .padding({ right: this.block.lang.length > 0 ? 48 : 0 })
      }
      .scrollable(ScrollDirection.Horizontal)
      .width('100%')
    }
    .width('100%')
    .padding(CODE_PAD)
    .backgroundColor($r('app.color.md_code_bg'))
    .borderRadius(CODE_RADIUS)
    .margin({ top: this.tightTop ? SPACE_TIGHT : SPACE_BLOCK })
  }

  // ===== 引用 =====

  @Builder
  QuoteBlock() {
    MdInlineText({
      inlines: this.block.inlines,
      bodySize: this.bodySize,
      lineHeight: this.lineHeight,
      dark: this.dark,
      accentColor: this.accentColor,
      onLink: this.onLink,
      tapToEdit: this.tapToEdit,
      onTextTap: this.onBlockTap,
      overrideColor: $r('app.color.text_secondary'),
      quoteMode: true
    })
      .width('100%')
      .margin({
        top: this.tightTop ? SPACE_TIGHT : SPACE_BLOCK,
        left: Math.max(0, (this.block.quoteDepth - 1) * QUOTE_DEPTH_INSET)
      })
  }

  // ===== 列表项 =====

  @Builder
  ListItemBlock() {
    Row({ space: 8 }) {
      Column() {
        if (this.block.task !== MdTaskState.None) {
          this.TaskMarker(this.block.task === MdTaskState.Done)
        } else if (this.block.ordered) {
          Text(`${this.listNumber}.`)
            .fontSize(this.bodySize)
            .fontColor($r('app.color.text_secondary'))
            .width(28)
            .textAlign(TextAlign.End)
        } else {
          Text(this.bulletFor(this.block.indent))
            .fontSize(this.bodySize * 0.9)
            .fontColor($r('app.color.text_secondary'))
            .width(20)
            .textAlign(TextAlign.Center)
        }
      }
      .width(this.block.ordered ? 32 : 24)
      .alignItems(HorizontalAlign.Center)

      MdInlineText({
        inlines: this.block.inlines,
        bodySize: this.bodySize,
        lineHeight: this.lineHeight,
        dark: this.dark,
        accentColor: this.accentColor,
        onLink: this.onLink,
        tapToEdit: this.tapToEdit,
        onTextTap: this.onBlockTap,
        overrideColor: this.block.task === MdTaskState.Done ? $r('app.color.text_secondary') : undefined,
        overrideStrike: this.block.task === MdTaskState.Done
      })
        .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding({ left: this.block.indent * LIST_INDENT })
    .margin({ top: this.tightTop ? SPACE_LIST_TIGHT : SPACE_BLOCK })
  }

  @Builder
  TaskMarker(done: boolean) {
    Column() {
      Text(done ? '✓' : '◯')
        .fontSize(16)
        .fontColor(done ? $r('app.color.on_accent') : $r('app.color.text_secondary'))
    }
    .width(TASK_HIT)
    .height(TASK_HIT)
    .borderRadius(TASK_HIT / 2)
    .backgroundColor(done ? this.accentColor : Color.Transparent)
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      this.onTaskToggle(this.block);
    })
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
  }

  // ===== 表格 =====

  @Builder
  TableBlock() {
    Scroll() {
      Column({ space: 0 }) {
        ForEach(this.block.rows, (row: MdTableRow, r: number) => {
          Row({ space: 0 }) {
            ForEach(row.cells, (cell: MdInline[], c: number) => {
              Column() {
                MdInlineText({
                  inlines: cell,
                  bodySize: this.bodySize,
                  lineHeight: this.lineHeight,
                  dark: this.dark,
                  accentColor: this.accentColor,
                  onLink: this.onLink,
        tapToEdit: this.tapToEdit,
        onTextTap: this.onBlockTap,
                  overrideWeight: row.header ? FontWeight.Medium : FontWeight.Normal
                })
              }
              .padding(8)
              .borderWidth({
                left: c > 0 ? 1 : 0,
                top: r > 0 ? 1 : 0
              })
              .borderColor($r('app.color.divider'))
              .backgroundColor(row.header ? $r('app.color.md_table_header_bg') : Color.Transparent)
              .layoutWeight(1)
              .alignItems(this.cellAlign(c))
              .constraintSize({ minWidth: TABLE_CELL_MIN_W })
            }, (cell: MdInline[], c: number) => `${c}`)
          }
          .width('100%')
        }, (row: MdTableRow, r: number) => `${r}`)
      }
      .width(this.tableWidth())
      .alignItems(HorizontalAlign.Start)
    }
    .scrollable(ScrollDirection.Horizontal)
    .width('100%')
    .margin({ top: this.tightTop ? SPACE_TIGHT : SPACE_BLOCK })
  }

  // ===== 分割线 =====

  @Builder
  DividerBlock() {
    Row()
      .width('100%')
      .height(1)
      .backgroundColor($r('app.color.divider'))
      .margin({ top: SPACE_BLOCK, bottom: SPACE_BLOCK })
  }

  // ===== 提示块 =====

  @Builder
  CalloutBlock() {
    this.CalloutSurface(this.calloutPaint(this.block.callout));
  }

  @Builder
  CalloutSurface(paint: CalloutPaint) {
    Column({ space: SPACE_TIGHT }) {
      Text(paint.label)
        .fontSize(this.bodySize * 0.75)
        .fontWeight(FontWeight.Medium)
        .fontColor(paint.text)
        .textCase(TextCase.UpperCase)

      MdInlineText({
        inlines: this.block.inlines,
        bodySize: this.bodySize,
        lineHeight: this.lineHeight,
        dark: this.dark,
        accentColor: this.accentColor,
        onLink: this.onLink,
        tapToEdit: this.tapToEdit,
        onTextTap: this.onBlockTap
      })
        .width('100%')
    }
    .width('100%')
    .padding(12)
    .backgroundColor(paint.bg)
    .borderWidth(1)
    .borderColor(paint.border)
    .borderRadius(CODE_RADIUS)
    .margin({ top: this.tightTop ? SPACE_TIGHT : SPACE_BLOCK })
  }

  // ===== 公式 =====

  /**
   * 块级公式。
   *
   * 只有一个块级公式走 ArkWeb：一屏十几个**行内**公式不进来，那会变成十几个
   * WebView（见 `FormulaWeb` 的注释）；行内公式由 `SpanBody` 用 `MathLite`
   * 线性化成 Unicode 文本。
   *
   * 卡片表面给 KaTeX 的页面让出内边距，是为了长公式换行时不贴边；页面自己量到
   * 高度后把数值报回来，这里只负责给这块一个宽度和一圈底色。
   */
  @Builder
  MathBlock() {
    Column() {
      FormulaWeb({
        code: this.block.code,
        dark: this.dark,
        fontPx: this.bodySize,
        textColor: this.dark ? '#F2F2F7' : '#1A1A1C',
        accent: this.accentColor,
        bg: 'transparent'
      })
    }
    .width('100%')
    .padding({ top: SPACE_TIGHT, bottom: SPACE_TIGHT, left: 4, right: 4 })
    .backgroundColor($r('app.color.md_math_bg'))
    .borderRadius(CODE_RADIUS)
    .margin({ top: this.tightTop ? SPACE_TIGHT : SPACE_BLOCK })
  }

  // ===== 工具方法 =====

  private headingSize(level: number): number {
    switch (level) {
      case 1: return this.bodySize * 1.6;
      case 2: return this.bodySize * 1.35;
      case 3: return this.bodySize * 1.2;
      case 4: return this.bodySize * 1.1;
      case 5: return this.bodySize * 1.0;
      case 6: return this.bodySize * 0.95;
      default: return this.bodySize;
    }
  }

  private headingWeight(level: number): FontWeight {
    if (level >= 1 && level <= 3) {
      return FontWeight.Bold;
    }
    return FontWeight.Medium;
  }

  private headingTopSpace(level: number): number {
    switch (level) {
      case 1: return SPACE_HEAD_ABOVE_H1;
      case 2: return SPACE_HEAD_ABOVE_H2;
      case 3: return SPACE_HEAD_ABOVE_H3;
      case 4: return SPACE_HEAD_ABOVE_H4;
      case 5: return SPACE_HEAD_ABOVE_H5;
      case 6: return SPACE_HEAD_ABOVE_H6;
      default: return SPACE_BLOCK;
    }
  }

  private headingBottomSpace(level: number): number {
    switch (level) {
      case 1: return SPACE_HEAD_BELOW_H1;
      case 2: return SPACE_HEAD_BELOW_H2;
      default: return SPACE_HEAD_BELOW_H3_H6;
    }
  }

  private bulletFor(indent: number): string {
    const depth: number = Math.max(0, indent);
    if (depth % 3 === 0) {
      return '•';
    } else if (depth % 3 === 1) {
      return '◦';
    }
    return '▪';
  }

  private cellAlign(column: number): HorizontalAlign {
    const align: number = this.block.aligns[column] ?? 0;
    switch (align) {
      case 1: return HorizontalAlign.Center;
      case 2: return HorizontalAlign.End;
      default: return HorizontalAlign.Start;
    }
  }

  private tableWidth(): number {
    const columns: number = this.block.rows.length > 0 ? this.block.rows[0].cells.length : 1;
    return Math.max(1, columns) * 96;
  }

  private tokenizedLines(): CodeToken[][] {
    if (CodeHighlight.supports(this.block.lang)) {
      return CodeHighlight.tokenizeLines(this.block.codeLines, this.block.lang);
    }
    return this.block.codeLines.map((line: string) => {
      const token: CodeToken = { text: line, style: CodeTokenStyle.Plain };
      return [token];
    });
  }

  private tokenColor(style: CodeTokenStyle): ResourceColor {
    switch (style) {
      case CodeTokenStyle.Keyword: return $r('app.color.md_code_keyword');
      case CodeTokenStyle.Str: return $r('app.color.md_code_string');
      case CodeTokenStyle.Num: return $r('app.color.md_code_number');
      case CodeTokenStyle.Comment: return $r('app.color.md_code_comment');
      case CodeTokenStyle.Func: return $r('app.color.md_code_func');
      case CodeTokenStyle.Type: return $r('app.color.md_code_type');
      case CodeTokenStyle.Punct: return $r('app.color.md_code_punct');
      case CodeTokenStyle.Tag: return $r('app.color.md_code_tag');
      case CodeTokenStyle.Attr: return $r('app.color.md_code_attr');
      case CodeTokenStyle.Meta: return $r('app.color.md_code_meta');
      default: return $r('app.color.md_code_plain');
    }
  }

  private calloutPaint(kind: MdCalloutKind): CalloutPaint {
    switch (kind) {
      case MdCalloutKind.Note:
        return {
          label: 'NOTE',
          bg: $r('app.color.md_callout_note_bg'),
          border: $r('app.color.md_callout_note_border'),
          text: $r('app.color.md_callout_note_text')
        };
      case MdCalloutKind.Tip:
        return {
          label: 'TIP',
          bg: $r('app.color.md_callout_tip_bg'),
          border: $r('app.color.md_callout_tip_border'),
          text: $r('app.color.md_callout_tip_text')
        };
      case MdCalloutKind.Important:
        return {
          label: 'IMPORTANT',
          bg: $r('app.color.md_callout_important_bg'),
          border: $r('app.color.md_callout_important_border'),
          text: $r('app.color.md_callout_important_text')
        };
      case MdCalloutKind.Warning:
        return {
          label: 'WARNING',
          bg: $r('app.color.md_callout_warning_bg'),
          border: $r('app.color.md_callout_warning_border'),
          text: $r('app.color.md_callout_warning_text')
        };
      case MdCalloutKind.Caution:
        return {
          label: 'CAUTION',
          bg: $r('app.color.md_callout_caution_bg'),
          border: $r('app.color.md_callout_caution_border'),
          text: $r('app.color.md_callout_caution_text')
        };
      default:
        return {
          label: 'NOTE',
          bg: $r('app.color.md_callout_note_bg'),
          border: $r('app.color.md_callout_note_border'),
          text: $r('app.color.md_callout_note_text')
        };
    }
  }
}

// ===== 行内文本渲染器 =====

@ComponentV2
struct MdInlineText {
  @Param inlines: MdInline[] = [];
  @Param bodySize: number = 17;
  @Param lineHeight: number = 175;
  @Param dark: boolean = false;
  @Param accentColor: string = '#0A59F7';
  @Param onLink: (href: string) => void = () => {};
  @Param overrideSize: number = 0;
  @Param overrideWeight: FontWeight = FontWeight.Normal;
  @Param overrideColor: ResourceColor | undefined = undefined;
  @Param overrideStrike: boolean = false;
  @Param quoteMode: boolean = false;
  /**
   * 编辑态：任意片段被点都回传「这一块被点了」，链接不再抢点击。
   *
   * 行内每个 `Span` 都挂了 `onClick`（链接要能点），点击会被 `Span` 消费，
   * 外层容器收不到；给自定义组件加 `.hitTestBehavior(HitTestMode.None)` 实测也
   * 不生效。唯一可靠的办法是在 `Span` 自己的回调里分流。
   */
  @Param tapToEdit: boolean = false;
  @Event onTextTap: () => void = () => {};

  /**
   * 正文可以**选中并复制**，即使此刻它同时是「点一下就编辑」的入口。
   *
   * 这两个属性是一组的：`copyOption` 决定长按要不要弹「复制 / 全选」菜单，
   * `textSelectable` 决定能不能拖出选区。用 `CopyOptions.LocalDevice` 而不是
   * `InApp`——复制到别的应用是这个功能全部的意义，只在本应用内可粘贴等于没有。
   *
   * **不要为了 `tapToEdit` 关掉它。** 单击与长按是两条独立的手势通道：单击仍然走
   * `Span.onClick` → `onBlockTap`（进入编辑），长按才唤出选择手柄并进入选区模式。
   * 两者不冲突（`text.d.ts` 里 `copyOption` 的说明也是「长按显示复制/全选菜单」，
   * 与点击无关）。代价是长按会先经过一段时间才判定，但此前这一页根本拿不到任何
   * 选区——能选中一段话去发消息，比长按快几十毫秒重要得多。
   *
   * 取 `SELECTABLE_UNFOCUSABLE` 而不是 `..._FOCUSABLE`：正文若可获得焦点，
   * 每次点正文都会抢走输入框的焦点，正在编辑的那一块会被迫收起键盘。
   */
  build() {
    if (this.quoteMode) {
      Text() {
        this.SpanBody()
      }
      .fontSize(this.baseFontSize())
      .fontColor($r('app.color.text_primary'))
      .lineHeight(this.baseLineHeight())
      .padding({ left: 12 })
      .borderWidth({ left: QUOTE_BAR_WIDTH })
      .borderColor(this.accentColor)
      .width('100%')
      .copyOption(CopyOptions.LocalDevice)
      .textSelectable(TextSelectableMode.SELECTABLE_UNFOCUSABLE)
    } else {
      Text() {
        this.SpanBody()
      }
      .fontSize(this.baseFontSize())
      .fontColor($r('app.color.text_primary'))
      .lineHeight(this.baseLineHeight())
      .width('100%')
      .copyOption(CopyOptions.LocalDevice)
      .textSelectable(TextSelectableMode.SELECTABLE_UNFOCUSABLE)
    }
  }

  @Builder
  SpanBody() {
    ForEach(this.inlines, (item: MdInline, index: number) => {
      Span(this.textFor(item))
        .fontSize(this.fontSizeFor(item))
        .fontColor(this.fontColorFor(item))
        .fontWeight(this.fontWeightFor(item))
        .fontStyle(this.fontStyleFor(item))
        .decoration(this.decorationFor(item))
        .fontFamily(this.fontFamilyFor(item))
        .textBackgroundStyle(this.backgroundFor(item))
        .baselineOffset(this.baselineFor(item))
        .onClick(() => {
          if (this.tapToEdit) {
            // 编辑态优先：这一下是「我要改这块」，不是「我要打开这个链接」。
            this.onTextTap();
            return;
          }
          if (item.kind === MdInlineKind.Link && item.href.length > 0) {
            this.onLink(item.href);
          }
        })
    }, (item: MdInline, index: number) => `${item.kind}-${item.text}-${index}`)
  }

  /**
   * 一个行内片段实际画出来的文字。
   *
   * 只有行内公式会改写：`$E = mc^2$` 交给 `MathLite` 压成 `E = mc²`，用正文
   * 字体渲染。这是**刻意的降级**，不是没做完——行内公式逐个塞 WebView 会让一屏
   * 十几个公式变成十几个浏览器进程（见 `FormulaWeb` 注释）。块级 `$$…$$` 才走
   * KaTeX，因为块级公式本来就少、且值得排版。
   */
  private textFor(item: MdInline): string {
    if (item.kind === MdInlineKind.MathInline) {
      return MathLite.linearize(item.text);
    }
    return item.text;
  }

  private baseFontSize(): number {
    return this.overrideSize > 0 ? this.overrideSize : this.bodySize;
  }

  private baseLineHeight(): number {
    const size: number = this.baseFontSize();
    return size * (this.lineHeight / 100);
  }

  private fontSizeFor(item: MdInline): number {
    const base: number = this.overrideSize > 0 ? this.overrideSize : this.bodySize * (item.size ?? 1);
    if (item.kind === MdInlineKind.Sup || item.kind === MdInlineKind.Sub) {
      return base * 0.75;
    }
    return base;
  }

  private fontColorFor(item: MdInline): ResourceColor {
    if (this.overrideColor !== undefined) {
      return this.overrideColor;
    }
    if (item.kind === MdInlineKind.Link) {
      return this.accentColor;
    }
    if (item.kind === MdInlineKind.Image) {
      return $r('app.color.text_secondary');
    }
    return $r('app.color.text_primary');
  }

  private fontWeightFor(item: MdInline): FontWeight {
    if (this.overrideWeight !== FontWeight.Normal) {
      return this.overrideWeight;
    }
    if (item.bold) {
      return FontWeight.Bold;
    }
    return FontWeight.Normal;
  }

  private fontStyleFor(item: MdInline): FontStyle {
    if (item.italic) {
      return FontStyle.Italic;
    }
    return FontStyle.Normal;
  }

  private decorationFor(item: MdInline): DecorationStyleInterface {
    const strike: boolean = item.strike || this.overrideStrike;
    if (strike) {
      return { type: TextDecorationType.LineThrough };
    }
    return { type: TextDecorationType.None };
  }

  /**
   * 字体族。
   *
   * **空串不行**：`.fontFamily('')` 让 Span 拿到一个不存在的族名，实测整行
   * 字形不绘制——布局高度还在，字看不见。所以「用默认字体」必须显式写成平台
   * 字体名，而不是留空。
   */
  private fontFamilyFor(item: MdInline): string {
    // 行内公式不排等宽：线性化之后是 `E = mc²` 这类普通字符串，等宽字体让它
    // 看起来像代码摘录而不是公式。块级公式在 `FormulaWeb` 里由 KaTeX 排。
    if (item.code) {
      return 'monospace';
    }
    return 'HarmonyOS Sans';
  }

  private backgroundFor(item: MdInline): TextBackgroundStyle {
    if (item.code) {
      return { color: $r('app.color.md_code_surface'), radius: 4 };
    }
    if (item.kind === MdInlineKind.Mark) {
      return { color: $r('app.color.md_mark_bg'), radius: 4 };
    }
    // 行内公式**不加底色**：线性化之后它是一段正文（`E = mc²`），给它套一层
    // 代码底色会让人以为那是引用的一段源码。块级公式自带卡片。
    return { color: Color.Transparent, radius: 0 };
  }

  private baselineFor(item: MdInline): LengthMetrics | undefined {
    if (item.kind === MdInlineKind.Sup) {
      return LengthMetrics.vp(this.fontSizeFor(item) * 0.35);
    }
    if (item.kind === MdInlineKind.Sub) {
      return LengthMetrics.vp(-this.fontSizeFor(item) * 0.25);
    }
    return undefined;
  }
}

// ===== 类型辅助 =====

interface CalloutPaint {
  label: string;
  bg: ResourceColor;
  border: ResourceColor;
  text: ResourceColor;
}
