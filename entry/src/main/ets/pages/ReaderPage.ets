import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { MdBlock, MdParseResult, MdSrcRange } from '../markdown/MdTypes';
import { MdParser } from '../markdown/MdParser';
import { EditableDocument } from '../markdown/EditableDocument';
import { WholeDocEditor } from '../markdown/WholeDocEditor';
import { Note } from '../models/Note';
import { NoteStore } from '../services/NoteStore';
import { SettingsStore } from '../services/SettingsStore';

/**
 * 打开笔记页的参数。
 *
 * `created` 由列表的「+」置为 true：从新建进来、一个字都没写就离开时，
 * 这一页负责把空笔记收掉，避免误触留下「无标题」。
 */
export interface ReaderParam {
  id: string;
  created: boolean;
}

/** 会话内只提示一次「点按段落就能改」。 */
let HINT_SHOWN: boolean = false;

/**
 * 笔记页 —— 打开就是可写的文章，没有「只读 / 编辑」模式。
 *
 * ## 为什么没有模式开关
 *
 * 笔记应用的初衷是「打开就能记」。多一道「点编辑」的门，等于每改一个字都要先
 * 声明意图；而「只读浏览」本来就不该是一种需要进入的状态——正文一直可点，
 * 点哪一块就改哪一块，其余保持渲染，看上去就是一篇排好版的文章。
 *
 * 页面上只有一件事可变：**哪一块正在被编辑**。这正是 Typora 那类工具的模型，
 * 也是参考实现的「实时预览」模式。
 *
 * ## 写回只经过 `srcRangeOf`
 *
 * 每块在原文里的行区间由解析器给出（块在原文里连续有序，用「下一块的起始行」
 * 推断结束行；末块没有下一块，所以显式传总行数）。替换区间时连同块之间的空行
 * 一起带走，再补一个回来，否则「改一块」会把相邻块粘到一起。
 *
 * ## 布局
 *
 * 两层 `Stack`：底层只负责上色的 `Column` 拥有 `expandSafeArea`，内容层绝不
 * 扩展——否则页头会钻到状态栏底下。`NavDestination` 的内容本来就起于状态栏
 * 下沿，所以页头是一条没有顶部内边距的 56 vp 行。
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

  /** 正在编辑的块下标；-1 表示没有。 */
  @Local editingIndex: number = -1;
  /** 该块的源码草稿。 */
  @Local editingSource: string = '';
  /** 正在文末追加新段落。 */
  @Local appending: boolean = false;
  /** 草稿的解析结果，供编辑态下方预览。 */
  @Local previewBlocks: MdBlock[] = [];
  @Local previewTick: number = 0;
  /**
   * 整篇输入（记事本式）。默认打开笔记后在点一下正文时进入。
   */
  @Local wholeEditing: boolean = false;
  /** 整篇输入的初始原文；只在打开时赋值一次，避免与输入互相覆盖。 */
  @Local wholeSource: string = '';
  /** 整篇输入的当前草稿。 */
  @Local wholeDraft: string = '';
  /** 打开整篇输入时的光标落点。 */
  @Local wholeCaret: number = 0;
  /** 设置 › 分块编辑（默认关）。关 → 整篇输入。 */
  @Local simpleEditing: boolean = true;
  /** 设置 › 格式按钮条（默认关）。 */
  @Local showFormatBar: boolean = false;
  /**
   * 渲染纪元：正文每变一次 +1。
   *
   * `MdBlock.id` 是解析序号，勾选待办、改措辞都不会改变它，而 `ForEach` 的 key
   * 不变时框架会复用旧节点——文件已经写成 `- [x]`，屏幕上的圆圈却还是空的。
   * 所以内容的任何变化都要让 key 跟着变。
   */
  @Local epoch: number = 0;

  private noteId: string = '';
  /** 首次进入时是否已经尝试过自动落光标。 */
  private autoOpened: boolean = false;
  /** 这篇笔记是不是刚刚从列表「+」新建的（用来判断要不要丢弃空笔记）。 */
  private createdHere: boolean = false;
  /** 本次进入后用户是否真的改过东西。 */
  private touched: boolean = false;
  /** 当前编辑块的原始源码，用来判断草稿是否真的偏离了原文。 */
  private initialSourceOfEditing: string = '';

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

  private bodyLines(): string[] {
    return this.note.body.split('\n');
  }

  private load(id: string): void {
    this.noteId = id;
    this.bodySize = SettingsStore.instance.editorFontSize;
    this.lineHeight = SettingsStore.instance.editorLineHeight;
    this.simpleEditing = SettingsStore.instance.simpleEditing;
    this.showFormatBar = SettingsStore.instance.formatBar;
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

    // 「打开就能记」：空白笔记一进来就把光标放好。已有内容的笔记不这么做——
    // 那会在用户只想看一眼前提下弹出键盘。`autoOpened` 保证只在首次进入时触发。
    if (!this.autoOpened) {
      this.autoOpened = true;
      const blank: boolean = this.blocks.length === 0
        || (this.blocks.length === 1 && this.blocks[0].kind === 0 && this.blocks[0].plain.trim() === '无标题');
      if (blank) {
        // 默认（整篇输入）直接在整篇输入框里落光标；分块模式才落进第一块。
        if (this.simpleEditing) {
          this.enterWholeEditingAt(0);
        } else if (this.blocks.length === 0) {
          this.startAppend();
        } else {
          this.openResolved(0);
        }
      }
    }
  }

  private reparse(body: string): void {
    this.note.body = body;
    const result: MdParseResult = MdParser.parse(body);
    this.blocks = result.blocks;
    this.title = this.note.title;
    this.epoch = this.epoch + 1;
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

  // ------------------------------------------------------------- 整篇输入

  /** 某一块首字符在正文里的偏移，用作「点哪儿光标落哪儿」。 */
  private caretAtBlock(index: number): number {
    if (index < 0 || index >= this.blocks.length) {
      return this.note.body.length;
    }
    const lines: string[] = this.bodyLines();
    const target: number = this.blocks[index].srcLine;
    let offset = 0;
    for (let i = 0; i < target && i < lines.length; i++) {
      offset += lines[i].length + 1;
    }
    return Math.min(offset, this.note.body.length);
  }

  private enterWholeEditingAt(index: number): void {
    this.commitPending();
    this.wholeCaret = this.caretAtBlock(index);
    this.wholeSource = this.note.body;
    this.wholeDraft = this.note.body;
    this.wholeEditing = true;
  }

  private commitWhole(): void {
    const next: string = this.wholeDraft;
    const changed: boolean = next !== this.wholeSource;
    this.wholeEditing = false;
    // 清空初始原文，下次打开时 `@Monitor('source')` 才会重新播种并落光标。
    this.wholeSource = '';
    if (changed) {
      this.touched = true;
      this.persist(next);
    }
  }

  // ------------------------------------------------------------- 就地编辑

  /**
   * 点中一块 → 就地展开它的源码。
   *
   * 切换块之前必须先提交当前块，否则草稿会丢。提交会重解析全文，所以点击时
   * 记下的下标可能已经偏移；这里用「原目标块的行号」在新结果里重新定位，
   * 找不到才退回原下标。
   */
  private openBlock(index: number): void {
    if (this.editingIndex === index && !this.appending) {
      return;
    }
    const targetLine: number = index >= 0 && index < this.blocks.length ? this.blocks[index].srcLine : -1;
    this.commitPending();

    let resolved = index;
    if (targetLine >= 0) {
      for (let i = 0; i < this.blocks.length; i++) {
        if (this.blocks[i].srcLine === targetLine) {
          resolved = i;
          break;
        }
      }
    }
    if (resolved < 0 || resolved >= this.blocks.length) {
      return;
    }
    this.openResolved(resolved);
  }

  private openResolved(index: number): void {
    const lines: string[] = this.bodyLines();
    const range: MdSrcRange = MdParser.srcRangeOf(this.blocks, index, lines.length);
    if (range.end <= range.start) {
      return;
    }
    const source: string = lines.slice(range.start, range.end).join('\n').replace(/\n+$/, '');
    this.appending = false;
    this.editingIndex = index;
    this.editingSource = source;
    this.initialSourceOfEditing = source;
    this.previewBlocks = MdParser.parse(source).blocks;
    this.previewTick = this.previewTick + 1;
  }

  /** 文末追加一段。 */
  private startAppend(): void {
    this.commitPending();
    this.editingIndex = -1;
    this.appending = true;
    this.editingSource = '';
    this.initialSourceOfEditing = '';
    this.previewBlocks = [];
    this.previewTick = this.previewTick + 1;
  }

  private onDraftChange(value: string): void {
    this.editingSource = value;
    // 只有内容**真的偏离原文**才算动过。
    //
    // 不能一见 onChange 就置真：输入框挂载时把初始文本写进去也会触发一次
    // onChange，于是刚点「+」什么都没写就被当成编辑过，离开时那个空的
    // 「无标题」就留在了列表里（实测）。
    if (value !== this.initialSourceOfEditing) {
      this.touched = true;
    }
    // 草稿是**单块**，量级只有几行，每键重解析的代价可忽略；不这样做，
    // 预览就变成「回车之后」而不是「实时」。
    this.previewBlocks = MdParser.parse(value).blocks;
    this.previewTick = this.previewTick + 1;
  }

  private commitPending(): void {
    if (this.wholeEditing) {
      this.commitWhole();
      return;
    }
    if (this.appending) {
      this.commitAppend();
      return;
    }
    if (this.editingIndex >= 0) {
      this.commitBlock();
    }
  }

  private clearEditing(): void {
    this.editingIndex = -1;
    this.appending = false;
    this.editingSource = '';
    this.previewBlocks = [];
  }

  /** 把草稿写回原文的该块行区间。 */
  private commitBlock(): void {
    const index = this.editingIndex;
    if (index < 0 || index >= this.blocks.length) {
      this.clearEditing();
      return;
    }
    const lines: string[] = this.bodyLines();
    const range: MdSrcRange = MdParser.srcRangeOf(this.blocks, index, lines.length);
    if (range.end <= range.start) {
      this.clearEditing();
      return;
    }
    const draft = this.editingSource.replace(/\n+$/, '');
    const replacement: string[] = draft.length === 0 ? [] : draft.split('\n');
    // 区间已经吞掉了块之间的空行，补一个回来，保证与下一块分离。
    replacement.push('');
    const next: string[] = lines.slice(0, range.start).concat(replacement, lines.slice(range.end));
    this.clearEditing();
    this.persist(next.join('\n'));
  }

  private commitAppend(): void {
    const draft = this.editingSource.replace(/\n+$/, '');
    if (draft.length === 0) {
      this.clearEditing();
      return;
    }
    const body = this.note.body.replace(/\n+$/, '');
    const next: string = body.length === 0 ? draft : `${body}\n\n${draft}`;
    this.clearEditing();
    this.persist(next);
  }

  /** 删除正在编辑的块（连同它的空行）。 */
  private deleteBlock(): void {
    if (this.appending) {
      this.clearEditing();
      return;
    }
    const index = this.editingIndex;
    if (index < 0 || index >= this.blocks.length) {
      this.clearEditing();
      return;
    }
    // 删一整段是不可逆的（只改正文，不进回收站），所以必须问一句。
    // 一个误触就抹掉一段正文，是这一页最容易造成真实损失的地方。
    this.getUIContext().showAlertDialog({
      title: '删除这一段？',
      message: '这一段会从笔记里移除，不能撤销。',
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: $r('app.color.danger'),
        action: () => {
          this.removeBlockNow(index);
        }
      }
    });
  }

  private removeBlockNow(index: number): void {
    if (index < 0 || index >= this.blocks.length) {
      this.clearEditing();
      return;
    }
    const lines: string[] = this.bodyLines();
    const range: MdSrcRange = MdParser.srcRangeOf(this.blocks, index, lines.length);
    if (range.end <= range.start) {
      this.clearEditing();
      return;
    }
    const next: string[] = lines.slice(0, range.start).concat(lines.slice(range.end));
    this.clearEditing();
    this.persist(next.join('\n'));
  }

  /**
   * 勾选任务列表并写回。
   *
   * 只翻这一行的第一组方括号——用正则整段替换会把同一行里的第二组一起改掉。
   */
  private toggleTask(block: MdBlock): void {
    this.commitPending();
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
    this.commitPending();
    // 从「+」进来、一个字都没写就离开：把空笔记收掉。
    // 不收的话，误触一次「+」就在列表里留一张「无标题」——正是这条规则存在的理由。
    // 只认准「未改动」且正文仍是骨架，所以读到一半离开的笔记绝不会被删。
    if (this.createdHere && !this.touched) {
      const body: string = this.note.body.trim();
      if (body.length === 0 || body === '# 无标题') {
        NoteStore.instance.purgeNote(this.note);
        this.onChanged();
      }
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
          } else if (this.wholeEditing) {
            // 记事本式的整篇输入。没有块、没有预览面板，只有一张输入框。
            WholeDocEditor({
              source: this.wholeSource,
              initialCaret: this.wholeCaret,
              bodySize: this.bodySize,
              showFormatBar: this.showFormatBar,
              accentColor: this.accentColor,
              onChange: (text: string) => {
                this.wholeDraft = text;
                if (text !== this.wholeSource) {
                  this.touched = true;
                }
              }
            })
          } else {
            Scroll() {
              Column() {
                EditableDocument({
                  blocks: this.blocks,
                  editingIndex: this.editingIndex,
                  editingSource: this.editingSource,
                  appending: this.appending,
                  simpleMode: this.simpleEditing,
                  showFormatBar: this.showFormatBar,
                  previewBlocks: this.previewBlocks,
                  previewTick: this.previewTick,
                  epoch: this.epoch,
                  bodySize: this.bodySize,
                  lineHeight: this.lineHeight,
                  dark: this.dark,
                  accentColor: this.accentColor,
                  onBlockTap: (index: number) => {
                    if (this.simpleEditing) {
                      this.enterWholeEditingAt(index);
                    } else {
                      this.openBlock(index);
                    }
                  },
                  onDraftChange: (value: string) => {
                    this.onDraftChange(value);
                  },
                  onCommit: () => {
                    this.commitPending();
                  },
                  onDelete: () => {
                    this.deleteBlock();
                  },
                  onTaskToggle: (block: MdBlock) => {
                    this.toggleTask(block);
                  },
                  onAddBlock: () => {
                    if (this.simpleEditing) {
                      // 整篇输入：光标落文末即可，不做块级追加。
                      this.enterWholeEditingAt(this.blocks.length);
                    } else {
                      this.startAppend();
                    }
                  }
                })
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
      const param = context.pathInfo.param as ReaderParam;
      this.createdHere = param.created;
      this.load(param.id);
      // 第一次进笔记时提示一次：这一页没有「编辑」按钮，点正文就是改。
      // 只在会话内提示一次——重复弹会变成噪音。
      if (!HINT_SHOWN) {
        HINT_SHOWN = true;
        setTimeout(() => {
          this.getUIContext().getPromptAction().showToast({ message: '点按任意段落就能修改' });
        }, 700);
      }
    })
    .onShown(() => {
      if (this.noteId.length > 0) {
        this.loadContinuation();
      }
    })
  }

  /**
   * 回到本页时重新读取。
   *
   * 只有在没有未提交草稿时才重解析：本页自己是唯一的写者，但如果从编辑器
   * 之类的页面返回，磁盘上的内容可能变了。有草稿就保留，不打断用户输入。
   */
  private loadContinuation(): void {
    if (this.wholeEditing || this.editingIndex >= 0 || this.appending) {
      return;
    }
    this.load(this.noteId);
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

      // 整篇输入时，完成只能放在页头：整篇输入框占满正文区，里面没有第二行
      // 可以放按钮的地方。
      if (this.wholeEditing) {
        Text('完成')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.accentColor)
          .padding({ left: 12, right: 8, top: 8, bottom: 8 })
          .onClick(() => {
            this.commitWhole();
          })
          .accessibilityText('完成编辑')
      }
    }
    .width('100%')
    .height(56)
    .padding({ left: 8, right: 12 })
    .backgroundColor($r('app.color.page_bg'))
  }

  /**
   * 正文一直处于可编辑状态（点哪块改哪块），行内 `Span` 的点击被用来「选中这一块」，
   * 所以链接不再是点击目标——与 Typora 的取舍一致：编辑态里点文字是放光标，
   * 不是打开网址。等接入「打开链接」的显式入口（长按菜单或顶部胶囊）再补。
   */
}
