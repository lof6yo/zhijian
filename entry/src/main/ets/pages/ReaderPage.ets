import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { MdBlock, MdParseResult, MdSrcRange } from '../markdown/MdTypes';
import { MdParser } from '../markdown/MdParser';
import { MdDocumentView } from '../markdown/MdView';
import { EditableDocument } from '../markdown/EditableDocument';
import { Note } from '../models/Note';
import { NoteStore } from '../services/NoteStore';
import { SettingsStore } from '../services/SettingsStore';

/**
 * 阅读 / 实时预览编辑页 —— 原生 Markdown 渲染 + 就地块编辑。
 *
 * ## 为什么阅读和编辑在同一页，而不再是两个页面
 *
 * Markdown 的源码是规范的一部分：用户写 `##`、`-`、`**`，这些符号一旦被藏进
 * 一个富文本编辑器的内部模型，用户就无法预测下一次输入会发生什么。所以「真正
 * 的所见即所得」不是把符号藏起来，而是**让符号和它的效果出现在同一个地方**：
 * 点哪一块，那一块就地展开成源码，下面立刻是它渲染出来的样子。
 *
 * 这带来一条明确的边界：本页只做**块级**就地编辑。不做跨块选区、不做自建光标
 * 模型——那是另一个编辑器的工程量，而且会把「所见即所得」变成「所见非所得」。
 *
 * ## 写回只经过 `srcRangeOf`
 *
 * 每一块在原文里的行区间由解析器给出（块在原文里连续且有序，用「下一块的起始行」
 * 推断结束行）。替换区间时**连同块之间的空行一起带走**，再补一个空行，这样
 * 「改一块」不会把相邻块粘到一起。末块没有「下一块」可借位，所以要显式传总行数，
 * 否则多行的末块只会被截到首行。
 *
 * ## 布局
 *
 * 两层 `Stack`：底层只负责上色的 `Column` 拥有 `expandSafeArea`，内容层绝不
 * 扩展——否则页头会钻到状态栏底下。`NavDestination` 的内容本来就起于状态栏下沿，
 * 所以页头是一条没有顶部内边距的 56 vp 行。
 */
@ComponentV2
export struct ReaderPage {
  @Param pathStack: NavPathStack = new NavPathStack();
  @Param accentColor: string = '#0A59F7';
  /** 内容变化后通知列表刷新。 */
  @Event onChanged: () => void = () => {};

  @Local note: Note = new Note();
  @Local blocks: MdBlock[] = [];
  @Local title: string = '';
  @Local bodySize: number = 17;
  @Local lineHeight: number = 175;
  @Local dark: boolean = false;
  @Local ready: boolean = false;

  /** 实时预览编辑模式。 */
  @Local editing: boolean = false;
  /** 正在编辑的块下标；-1 表示没有块处于编辑态。 */
  @Local editingIndex: number = -1;
  /** 该块的源码草稿。 */
  @Local editingSource: string = '';
  /** 草稿的解析结果，供编辑态下方预览。 */
  @Local previewBlocks: MdBlock[] = [];
  @Local previewTick: number = 0;

  private noteId: string = '';

  private systemIsDark(): boolean {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    return context.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
  }

  private activeDark(): boolean {
    const mode = SettingsStore.instance.themeMode;
    if (mode === 2) {
      return true;
    }
    if (mode === 1) {
      return false;
    }
    return this.systemIsDark();
  }

  /** 正文按行切开。写回、取块区间都基于它。 */
  private bodyLines(): string[] {
    return this.note.body.split('\n');
  }

  private load(id: string): void {
    this.noteId = id;
    this.bodySize = SettingsStore.instance.editorFontSize;
    this.lineHeight = SettingsStore.instance.editorLineHeight;
    this.dark = this.activeDark();
    const note = NoteStore.instance.find(id);
    if (note === undefined) {
      this.ready = false;
      return;
    }
    this.note = note;
    this.title = note.title;
    const result: MdParseResult = MdParser.parse(note.body);
    this.blocks = result.blocks;
    this.ready = true;
  }

  /** 重新解析全文并刷新块列表。 */
  private reparse(body: string): void {
    this.note.body = body;
    const result: MdParseResult = MdParser.parse(body);
    this.blocks = result.blocks;
    this.title = this.note.title;
  }

  /**
   * 写盘并刷新。
   *
   * `saveNote()` 只在 H1 与文件名不一致时才改名，所以块编辑不会重命名文件；
   * 它同时刷新 `updatedAt`，同步据此判定为一次编辑并推送。
   */
  private persist(body: string): void {
    NoteStore.instance.saveNote(this.note, body);
    this.reparse(body);
    this.onChanged();
  }

  // ------------------------------------------------------------- 块编辑

  private enterEditMode(): void {
    this.editing = true;
    this.editingIndex = -1;
  }

  /** 退出编辑模式；未提交的块先提交，避免草稿丢失。 */
  private exitEditMode(): void {
    if (this.editingIndex >= 0) {
      this.commitBlock();
    }
    this.editing = false;
    this.editingIndex = -1;
  }

  /**
   * 点中一块 → 就地展开源码。
   *
   * 预览立刻用「该块当前源码」解析一次，而不是留空：一进来就该看到它现在的样子，
   * 否则用户会以为这块没内容。
   */
  private openBlock(index: number): void {
    if (!this.editing) {
      return;
    }
    const lines: string[] = this.bodyLines();
    const range: MdSrcRange = MdParser.srcRangeOf(this.blocks, index, lines.length);
    if (range.end <= range.start) {
      return;
    }
    const source: string = lines.slice(range.start, range.end).join('\n').replace(/\n+$/, '');
    this.editingIndex = index;
    this.editingSource = source;
    this.previewBlocks = MdParser.parse(source).blocks;
    this.previewTick = this.previewTick + 1;
  }

  private onDraftChange(value: string): void {
    this.editingSource = value;
    // 每次按键都重解析草稿。草稿是**单块**，量级只有几行，代价可忽略；
    // 不这样做的话预览就不是「实时」，而是「回车之后」。
    this.previewBlocks = MdParser.parse(value).blocks;
    this.previewTick = this.previewTick + 1;
  }

  /** 把草稿写回原文的该块行区间。 */
  private commitBlock(): void {
    const index = this.editingIndex;
    if (index < 0 || index >= this.blocks.length) {
      this.editingIndex = -1;
      return;
    }
    const lines: string[] = this.bodyLines();
    const range: MdSrcRange = MdParser.srcRangeOf(this.blocks, index, lines.length);
    if (range.end <= range.start) {
      this.editingIndex = -1;
      return;
    }
    const draft = this.editingSource.replace(/\n+$/, '');
    const replacement: string[] = draft.length === 0 ? [] : draft.split('\n');
    // 区间已经吞掉了块之间的空行，所以补一个回来，保证与下一块分离。
    replacement.push('');
    const next: string[] = lines.slice(0, range.start).concat(replacement, lines.slice(range.end));
    this.editingIndex = -1;
    this.editingSource = '';
    this.previewBlocks = [];
    this.persist(next.join('\n'));
  }

  /** 删除该块（连同它的空行）。 */
  private deleteBlock(): void {
    const index = this.editingIndex;
    if (index < 0 || index >= this.blocks.length) {
      this.editingIndex = -1;
      return;
    }
    const lines: string[] = this.bodyLines();
    const range: MdSrcRange = MdParser.srcRangeOf(this.blocks, index, lines.length);
    if (range.end <= range.start) {
      this.editingIndex = -1;
      return;
    }
    const next: string[] = lines.slice(0, range.start).concat(lines.slice(range.end));
    this.editingIndex = -1;
    this.editingSource = '';
    this.previewBlocks = [];
    this.persist(next.join('\n'));
  }

  /**
   * 勾选任务列表并写回。
   *
   * 阅读态也能勾选：勾一下是「结清一件事」，不是「改文章」，不该要求先进编辑模式。
   * 只翻这一行的第一组方括号——用正则整段替换会把同一行里的第二组一起改掉。
   */
  private toggleTask(block: MdBlock): void {
    const lines: string[] = this.bodyLines();
    if (block.srcLine < 0 || block.srcLine >= lines.length) {
      return;
    }
    const line = lines[block.srcLine];
    const next = block.task === 1 ? line.replace('[x]', '[ ]').replace('[X]', '[ ]')
      : line.replace('[ ]', '[x]');
    if (next === line) {
      return;
    }
    lines[block.srcLine] = next;
    this.persist(lines.join('\n'));
  }

  private goBack(): void {
    if (this.editing && this.editingIndex >= 0) {
      this.commitBlock();
    }
    this.pathStack.pop();
  }

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.TopStart }) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor($r('app.color.page_bg'))
          .hitTestBehavior(HitTestMode.None)
          .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

        Column() {
          this.Header()

          if (!this.ready) {
            Column({ space: 8 }) {
              Text('笔记不存在')
                .fontSize(15)
                .fontColor($r('app.color.text_primary'))
              Text('它可能已经被删除，或者正在同步中被另一个设备移走。')
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
                .textAlign(TextAlign.Center)
            }
            .layoutWeight(1)
            .width('100%')
            .justifyContent(FlexAlign.Center)
          } else {
            Scroll() {
              Column() {
                if (this.editing) {
                  EditableDocument({
                    blocks: this.blocks,
                    editingIndex: this.editingIndex,
                    editingSource: this.editingSource,
                    previewBlocks: this.previewBlocks,
                    previewTick: this.previewTick,
                    bodySize: this.bodySize,
                    lineHeight: this.lineHeight,
                    dark: this.dark,
                    accentColor: this.accentColor,
                    onBlockTap: (index: number) => {
                      this.openBlock(index);
                    },
                    onDraftChange: (value: string) => {
                      this.onDraftChange(value);
                    },
                    onCommit: () => {
                      this.commitBlock();
                    },
                    onDelete: () => {
                      this.deleteBlock();
                    }
                  })
                } else {
                  MdDocumentView({
                    blocks: this.blocks,
                    bodySize: this.bodySize,
                    lineHeight: this.lineHeight,
                    dark: this.dark,
                    accentColor: this.accentColor,
                    onLink: (href: string) => {
                      this.handleLink(href);
                    },
                    onTaskToggle: (block: MdBlock) => {
                      this.toggleTask(block);
                    }
                  })
                }
              }
              .width('100%')
              .padding({ left: 20, right: 20, top: 4, bottom: 48 })
              .alignItems(HorizontalAlign.Start)
            }
            .width('100%')
            .layoutWeight(1)
            .scrollBar(BarState.Auto)
            .align(Alignment.TopStart)
          }
        }
        .width('100%')
        .height('100%')
      }
      .width('100%')
      .height('100%')
    }
    .hideTitleBar(true)
    .onBackPressed(() => {
      this.goBack();
      return true;
    })
    .onReady((context: NavDestinationContext) => {
      const id = context.pathInfo.param as string;
      this.load(id);
    })
    // 从其它页面返回时重新解析：`onShown` 每次转场都会触发，与是否带 `pop`
    // 结果无关（`pushPath({ onPop })` 只在 `pop(result)` 带结果时才回调）。
    .onShown(() => {
      if (this.noteId.length > 0) {
        this.load(this.noteId);
      }
    })
  }

  @Builder
  Header() {
    Row({ space: 4 }) {
      Button('‹')
        .fontSize(28)
        .fontColor($r('app.color.text_primary'))
        .backgroundColor(Color.Transparent)
        .width(44)
        .height(44)
        .onClick(() => {
          this.goBack();
        })
        .accessibilityText('返回笔记列表')

      Text(this.title.length > 0 ? this.title : '无标题')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)

      Text(this.editing ? '完成' : '编辑')
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.accentColor)
        .padding({ left: 12, right: 8, top: 8, bottom: 8 })
        .onClick(() => {
          if (this.editing) {
            this.exitEditMode();
          } else {
            this.enterEditMode();
          }
        })
        .accessibilityText(this.editing ? '退出编辑' : '进入编辑')
    }
    .width('100%')
    .height(56)
    .padding({ left: 8, right: 12 })
    .backgroundColor($r('app.color.page_bg'))
  }

  /**
   * 链接处理。
   *
   * 阅读时不跳浏览器：纸见是本地优先应用，没有内置浏览器，把用户踢出去会丢掉
   * 滚动位置；复制地址是可逆的。站内锚点目前是空操作——复制 `#` 开头的片段对
   * 用户没有意义，目录跳转要等大纲栏接入后由它承担。
   */
  private handleLink(href: string): void {
    if (href.length === 0 || href.startsWith('#')) {
      return;
    }
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, href);
      pasteboard.getSystemPasteboard().setDataSync(data);
      this.getUIContext().getPromptAction().showToast({ message: '链接已复制' });
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(0x0000, 'HMStartReader', 'copy link failed code=%{public}d', err.code);
      this.getUIContext().getPromptAction().showToast({ message: '复制失败' });
    }
  }
}
