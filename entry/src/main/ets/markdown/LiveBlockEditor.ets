import { MdBlock, emptyBlock } from './MdTypes';
import { MdBlockView } from './MdView';

/**
 * 就地编辑一块。
 *
 * ## 为什么是「改源码 + 看渲染」而不是富文本光标
 *
 * 真正所见即所得的富文本编辑器要自建光标模型：选区跨块、撤销栈、输入法组词、
 * 粘贴时的结构推断——那是一整个编辑器内核。而 Markdown 的源码本身就是规范的一部分，
 * 用户写 `##`、`-`、`**`，这些符号一旦被藏进内部模型，下一次输入会发生什么就不可
 * 预测。**源码在上、渲染在下**，反馈闭环完整，但不需要第二套文档模型。
 *
 * ## 为什么必须有格式按钮条
 *
 * 不熟悉 Markdown 的人只会写纯文字。没有按钮条，他能改字、能加段，但永远变不出
 * 标题、列表、待办、表格——功能存在却不可达，等于没有。「功能可以简单，但要闭环」
 * 要求这些动作是**可点出来的**，而不是要求用户先学会语法。
 *
 * 按钮只做两件事：行级前缀开关（标题/列表/待办/引用）和行内包裹（粗体/斜体/代码），
 * 外加一个表格骨架。刻意不做工具栏全家桶——那会把「改一句话」变成「选格式」。
 *
 * ## 三条踩过的边界
 *
 * 1. **组件，不是 `@Builder`。** 在 `ForEach` 的 itemGenerator 里调 `@Builder`
 *    本工程有过白屏先例。
 * 2. **组件不碰原文。** 只持有草稿并回调，写回由宿主按行区间完成。
 * 3. **焦点切换必须在两三帧内交接**，否则系统会先把输入法收起再弹出来。
 */
@ComponentV2
export struct LiveBlockEditor {
  @Param block: MdBlock = emptyBlock();
  @Param index: number = -1;
  @Param previewBlocks: MdBlock[] = [];
  /**
   * 预览刷新计数。块 id 是解析序号、打字时不变，不把它并进 `ForEach` 的 key，
   * 框架会复用旧节点，预览看起来「不刷新」。
   */
  @Param previewTick: number = 0;
  @Param bodySize: number = 17;
  @Param lineHeight: number = 175;
  @Param dark: boolean = false;
  @Param accentColor: string = '#0A59F7';
  /** 宿主传入的初始源码。 */
  @Param initialSource: string = '';
  /** 追加新段落时，标签显示「新段落」而不是沿用上一块的类型。 */
  @Param appendMode: boolean = false;

  @Local draft: string = '';
  /** 当前选区，用于「粗体 / 斜体 / 代码」包裹。 */
  @Local selStart: number = 0;
  @Local selEnd: number = 0;
  /** 已经播种过的源码，用来判断 `initialSource` 是否真的换了。 */
  @Local seeded: string = '';

  @Event onDraftChange: (value: string) => void = () => {};
  @Event onCommit: () => void = () => {};
  @Event onDelete: () => void = () => {};

  private controller: TextAreaController = new TextAreaController();

  aboutToAppear(): void {
    this.seed();
    this.focusNow();
    // 焦点要挤进一帧之内交接：中间空档一长，系统会先收起输入法再随新组件弹出。
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
   * `initialSource` 变化时重新播种草稿。
   *
   * 必须有这一步：从「正在编辑某一块」切到「文末追加」时，框架会**复用**同一个
   * 组件实例（结构位置没变），`aboutToAppear` 不会再跑，于是输入框里留着上一块的
   * 源码——用户以为在写新段落，实际在改上一段。
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

  /** 输入框 id 带块下标：共用固定 id 时，切块那一帧会命中正在销毁的旧节点。 */
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

  /** 写回草稿并把光标放到指定位置。 */
  private applyText(next: string, caret: number): void {
    this.draft = next;
    this.onDraftChange(next);
    const pos: number = caret < 0 ? 0 : caret;
    setTimeout(() => {
      try {
        this.controller.caretPosition(pos);
      } catch (e) {
        // 光标定位失败不影响内容，下一次输入会自然落到末尾。
      }
    }, 0);
  }

  /** 已知的块级前缀，长的在前——否则 `- [ ] ` 会被 `- ` 抢先剥掉。 */
  private linePrefixes(): string[] {
    return ['- [ ] ', '- [x] ', '- ', '* ', '+ ', '> ', '###### ', '##### ', '#### ', '### ', '## ', '# '];
  }

  private stripLinePrefix(line: string): string {
    const prefixes: string[] = this.linePrefixes();
    for (const p of prefixes) {
      if (line.startsWith(p)) {
        return line.substring(p.length);
      }
    }
    return line;
  }

  /**
   * 行级前缀开关：整块已经有这个前缀就去掉，否则先剥掉别的再加。
   *
   * 空行不动——否则在代码块/表格里加列表会把结构改坏。
   */
  private togglePrefix(prefix: string): void {
    const lines: string[] = this.draft.split('\n');
    let allHave: boolean = lines.length > 0;
    for (const line of lines) {
      if (line.trim().length > 0 && !line.startsWith(prefix)) {
        allHave = false;
        break;
      }
    }
    const out: string[] = [];
    for (const line of lines) {
      if (line.trim().length === 0) {
        out.push(line);
        continue;
      }
      const bare: string = this.stripLinePrefix(line);
      out.push(allHave ? bare : prefix + bare);
    }
    const next: string = out.join('\n');
    this.applyText(next, next.length);
  }

  /** 行内包裹：有选区就包住选区，没有就在光标处插入一对标记并停在中间。 */
  private wrapSelection(marker: string): void {
    const text: string = this.draft;
    const start: number = Math.min(this.selStart, this.selEnd);
    const end: number = Math.max(this.selStart, this.selEnd);
    if (start === end) {
      const next: string = text.substring(0, start) + marker + marker + text.substring(end);
      this.applyText(next, start + marker.length);
      return;
    }
    const picked: string = text.substring(start, end);
    const next: string = text.substring(0, start) + marker + picked + marker + text.substring(end);
    this.applyText(next, end + marker.length * 2);
  }

  /** 插入一个 2×2 表格骨架——手抄 `| --- |` 对不熟语法的人是不可能的。 */
  private insertTable(): void {
    const skeleton: string = '| 列 1 | 列 2 |\n| --- | --- |\n| 内容 | 内容 |';
    const base: string = this.draft.replace(/\n+$/, '');
    const next: string = base.length === 0 ? skeleton : `${base}\n\n${skeleton}`;
    this.applyText(next, next.length);
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
      case 9:
        return '图表';
      default:
        return '段落';
    }
  }

  @Builder
  FormatChip(label: string, onTap: () => void) {
    Text(label)
      .fontSize(12)
      .fontColor($r('app.color.text_primary'))
      .padding({ left: 10, right: 10, top: 6, bottom: 6 })
      .borderRadius(9)
      .backgroundColor($r('app.color.chip_bg'))
      .onClick(onTap)
      .accessibilityText(label)
  }

  build() {
    Column({ space: 8 }) {
      // 头部：正在编辑 · 类型 ＋ 删除 / 完成。
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

      // 格式按钮条。横向可滚，窄屏也不会挤成两行。
      Scroll() {
        Row({ space: 6 }) {
          this.FormatChip('标题', () => {
            this.togglePrefix('## ');
          })
          this.FormatChip('粗体', () => {
            this.wrapSelection('**');
          })
          this.FormatChip('斜体', () => {
            this.wrapSelection('*');
          })
          this.FormatChip('列表', () => {
            this.togglePrefix('- ');
          })
          this.FormatChip('待办', () => {
            this.togglePrefix('- [ ] ');
          })
          this.FormatChip('引用', () => {
            this.togglePrefix('> ');
          })
          this.FormatChip('表格', () => {
            this.insertTable();
          })
          this.FormatChip('代码', () => {
            this.wrapSelection('`');
          })
        }
        .padding({ right: 4 })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .align(Alignment.Start)

      TextArea({
        text: $$this.draft,
        placeholder: '直接输入文字；要标题、列表、粗体，点上面的按钮',
        controller: this.controller
      })
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
        .border({ width: { top: 1 }, color: $r('app.color.divider'), style: BorderStyle.Dashed })
      }
    }
    .width('100%')
    .padding({ top: 8, bottom: 12 })
    .alignItems(HorizontalAlign.Start)
  }
}
