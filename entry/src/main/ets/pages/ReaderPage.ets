import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import { TextSelectionClearPolicy } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { MdBlock, MdParseResult, MdSrcRange } from '../markdown/MdTypes';
import { MdParser } from '../markdown/MdParser';
import { EditableDocument } from '../markdown/EditableDocument';
import { WholeDocEditor } from '../markdown/WholeDocEditor';
import { Note } from '../models/Note';
import { NoteStore } from '../services/NoteStore';
import { SettingsStore } from '../services/SettingsStore';
import { AiClient, AiReply } from '../services/AiClient';
import { Haptics } from '../common/Haptics';

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

const DOMAIN: number = 0x0000;

/** 悬浮按钮直径。40 vp 是「一眼可点」与「别挡字」之间的折中。 */
const FLOAT_HIT: number = 40;
/** 悬浮按钮离屏幕边缘的距离。 */
const FLOAT_INSET: number = 16;
/** 悬浮按钮组的顶边距（正文区顶部，状态栏之下）。 */
const FLOAT_TOP: number = 8;
/** 同一排按钮之间的间距。 */
const FLOAT_GAP: number = 8;
/** 正文顶部为悬浮按钮让出的空间：按钮底边 + 一点呼吸。 */
const CONTENT_TOP_INSET: number = 64;

/**
 * 一步 AI 动作。
 *
 * `scenario` 决定用哪个模型（`SettingsStore.modelFor()`）；`system` 是这一步的
 * 提示词，写在这里而不是服务里，因为「润色」与「格式修正」的分界是产品选择，
 * 不是传输细节。`wholeBody` 为真时把整篇正文发过去（三个动作都是整篇）。
 */
interface AiAction {
  label: string;
  icon: Resource;
  scenario: number;
  system: string;
}

const AI_ACTIONS: AiAction[] = [
  {
    label: '翻译',
    icon: $r('sys.symbol.translate'),
    scenario: 1,
    system: '把下面这篇 Markdown 笔记翻译成中文；如果原文已经是中文，就翻译成英文。' +
      '只输出译文本身，保留原有的 Markdown 结构与代码块，不要加任何解释。'
  },
  {
    label: '格式',
    icon: $r('sys.symbol.doc_text_badge_checkmark'),
    scenario: 0,
    system: '整理下面这篇 Markdown 笔记的格式：统一标题层级、列表符号、空行与代码块围栏。' +
      '不得改写任何文字内容。只输出整理后的 Markdown，不要加任何解释。'
  },
  {
    label: '润色',
    icon: $r('sys.symbol.wand_and_stars'),
    scenario: 2,
    system: '润色下面这篇 Markdown 笔记：让表达更准确、通顺、简洁，保持原意与 Markdown 结构。' +
      '只输出润色后的 Markdown，不要加任何解释。'
  }
];

/** 撤销栈上限。50 步足够覆盖一次写作会话，再多只会让内存跟着一篇长文线性增长。 */
const UNDO_LIMIT: number = 50;

/**
 * `GlassButton` 的「哪一档决定灰不灰」。
 *
 * 传数字而不是布尔值：见 `GlassButton` 的注释——`@Builder` 的参数按值传，
 * `!this.canUndo` 在调用处求值就断了依赖，撤销钮会永远停在初始的灰。
 */
const GATE_NONE: number = 0;
const GATE_UNDO: number = 1;
const GATE_REDO: number = 2;

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
 * ## 布局：没有顶栏，只有两组悬浮玻璃按钮
 *
 * 曾经这里是一条 56 vp 的实心顶栏：左边返回、中间标题、右边完成。它有两个问题，
 * 都不是「再调一下间距」能解决的：
 *
 * 1. **标题是重复的。** 读者页的身份由正文的 H1 承担（列表卡片也是从 H1 取的
 *    标题），顶栏再写一遍，等于一屏里同一个名字出现两次，还遮掉正文。
 * 2. **一整条实心行只为放三个按钮。** 它把内容区往下压了 56 vp，而其中大部分
 *    是空的。
 *
 * 现在正文从屏幕顶部开始，两组 40 vp 的玻璃圆钮**浮在内容之上**：左上是返回，
 * 右上是「撤销 / 重做 / 模式 / AI」一排。它们不占布局高度，滚动起来正文从玻璃
 * 底下穿过——这正是「内容在纸上流动、控件浮在上面」的观感。代价是正文顶部要
 * 让出 `CONTENT_TOP_INSET`（见下），否则第一行字被按钮压住。
 *
 * 玻璃是手搓的，**不能用 `systemMaterial`**：沉浸材质只在 `Navigation` /
 * `NavDestination` 标题栏以及 `Toggle` 等特定组件里生效，直接放在内容区里实测
 * 不生效（见 AGENTS.md）。所以这里沿用 `Index.CircleAction` 的降级形态：
 * 一层 `backgroundEffect` 背景模糊 + 一层上缘高光渐变 + 一圈 1 vp 细边。
 *
 * 两层 `Stack` 的分工没有变：底层只负责上色的 `Column` 拥有 `expandSafeArea`，
 * 内容层绝不扩展——否则内容会钻到状态栏底下。
 */
@ComponentV2
export struct ReaderPage {
  @Param pathStack: NavPathStack = new NavPathStack();
  @Param accentColor: string = '#0A59F7';
  /** 内容变化后通知列表刷新。 */
  @Event onChanged: () => void = () => {};

  @Local note: Note = new Note();
  @Local blocks: MdBlock[] = [];
  /**
   * 笔记标题。
   *
   * 顶栏已经不显示了（身份由正文 H1 承担），但**不删这个字段**：它跟着
   * `saveNote()` 一起更新，是「文件真的改了名字 / 改了 H1」的现成信号。
   * 以后要做「标题变了就提示」时不用再解析一遍。
   */
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
  @Local simpleEditing: boolean = false;
  /** 设置 › 格式按钮条（默认关）。 */
  @Local showFormatBar: boolean = false;
  /** AI 面板是否展开。 */
  @Local aiPanelOpen: boolean = false;
  /** 一次 AI 请求是否在飞。用来禁用重复点击，并按需显示进度。 */
  @Local aiBusy: boolean = false;
  /** 最近一次 AI 结果面板是否打开。 */
  @Local aiResultShown: boolean = false;
  /** AI 返回的全文（尚未写回正文）。 */
  @Local aiResult: string = '';
  /** 产生这份结果的动作名，用于提示与面板标题。 */
  @Local aiActionLabel: string = '';
  /**
   * 撤销 / 重做是否可用。
   *
   * `undoStack` / `redoStack` 是普通私有字段，改了不会触发重绘，所以按钮的
   * 「灰不灰」不能直接读它们的 `length`——必须另存两个 `@Local` 快照，在
   * 每次进出栈之后显式刷新。K 这一页反复踩过：普通单例的字段变化不会让界面更新。
   */
  @Local canUndo: boolean = false;
  @Local canRedo: boolean = false;
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
  /**
   * 文档级撤销栈：存的是**每次写盘之前**的正文。
   *
   * ## 为什么自己做，而不是用输入框自带的撤销
   *
   * `TextArea` 的撤销栈没有对外接口，而且它只覆盖「一次连续输入」——块编辑里
   * 提交一块、再改另一块，两次改动在输入框眼里是两段互不相干的历史。用户要的是
   * 「把刚才那步撤掉」，那一步可能是分块编辑的一次提交、一次待办勾选、一次
   * 块删除，甚至一次整篇输入的完成。所以历史的粒度就是**一次写盘**，两条编辑
   * 路径共用一份。
   *
   * 粒度是「整篇正文」而不是「增量 diff」：一次写盘的产物本来就只是那一个字符串，
   * 存整篇最简单、也不可能还原错位；上限 50 步，一篇百万字的笔记极端情况下也就
   * 几十 MB，且只在同一页会话内存在，退出即释放。
   */
  private undoStack: string[] = [];
  /** 重做栈：被撤销掉的正文。任何一次新的写盘都会清空它。 */
  private redoStack: string[] = [];
  /** 当前历史对应的笔记 id；换一篇就把两个栈清空（见 `load()`）。 */
  private loadedId: string = '';

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
    // 换了笔记就清空历史：撤销栈存的是整篇正文，跨笔记复用会让「撤销」把另一篇
    // 的内容写进这一篇。判据是 `loadedId`，而不是 `noteId`——后者在 `load()`
    // 第一行就被改成入参了，永远相等。`loadContinuation()` 重读同一篇不清：
    // 那是同一段写作会话里的刷新。
    if (this.loadedId !== id) {
      this.undoStack = [];
      this.redoStack = [];
      this.syncHistoryFlags();
      this.loadedId = id;
    }
    const result: MdParseResult = MdParser.parse(note.body);
    this.blocks = result.blocks;
    this.ready = true;

    // 「打开就能记」只针对**刚新建**的那一篇（`createdHere`）。
    //
    // 之前这条规则也作用于「内容为空/只剩骨架标题」的已有笔记，结果列表里一堆
    // 无标题笔记，点进去必然落在编辑框里——把阅读页变成了编辑器，笔记一打开就
    // 「可改」，看不到它本来的样子。已有笔记一律以渲染态打开。
    if (!this.autoOpened) {
      this.autoOpened = true;
      if (this.createdHere) {
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
   *
   * 这里是**唯一**记历史的地方：任何改变正文的动作（块提交、块删除、待办勾选、
   * 整篇输入的完成、文末追加）最终都会落到这一处，所以这一次写盘就是一次
   * 「可以撤销的操作」。撤销 / 重做自己不走这条路径——否则撤销会把自己也记进
   * 历史，按两下撤销就等于原地不动。
   */
  private persist(body: string): void {
    this.pushHistory(this.note.body, body);
    NoteStore.instance.saveNote(this.note, body);
    this.reparse(body);
    this.onChanged();
  }

  // ------------------------------------------------------------- 撤销 / 重做

  /**
   * `before` / `after` 都要传。
   *
   * 原来只传 `before`，然后用 `before !== this.note.body` 判断「有没有变」——
   * 而 `this.note.body` 此刻**还是旧值**（`persist` 先记历史、后 `reparse`），
   * 于是这个比较永远是 false，撤销栈一条都进不去，撤销按钮全程是灰的。
   * 「变没变」必须拿**旧正文**和**即将写入的新正文**比，不能拿旧正文和自己比。
   */
  private pushHistory(before: string, after: string): void {
    // 内容没变就不是一步操作。没有这道判断，打开一篇笔记后先改一个字再改回来，
    // 撤销栈里会多出一个「等于当前正文」的项，按撤销看起来毫无反应。
    // 重复内容不重复入栈，但仍要清空重做栈：新的写盘意味着「另一条未来」。
    if (before !== after) {
      this.undoStack.push(before);
      while (this.undoStack.length > UNDO_LIMIT) {
        this.undoStack.shift();
      }
    }
    this.redoStack = [];
    this.syncHistoryFlags();
  }

  private syncHistoryFlags(): void {
    this.canUndo = this.undoStack.length > 0;
    this.canRedo = this.redoStack.length > 0;
  }

  /**
   * 撤销一步。
   *
   * `target` 是「要恢复成的那段正文」。恢复时**必须**先把正在编辑的草稿提交掉：
   * 不提交的话，草稿还挂在 `editingSource` 里，用户下一次点「完成」就会把撤销
   * 掉的文字又写回去——撤销看起来失效，实际是被草稿覆盖了。
   */
  private undo(): void {
    this.commitPending();
    if (this.undoStack.length === 0) {
      return;
    }
    const target: string | undefined = this.undoStack.pop();
    if (target === undefined) {
      return;
    }
    this.redoStack.push(this.note.body);
    this.applyHistory(target);
  }

  private redo(): void {
    this.commitPending();
    if (this.redoStack.length === 0) {
      return;
    }
    const target: string | undefined = this.redoStack.pop();
    if (target === undefined) {
      return;
    }
    this.undoStack.push(this.note.body);
    this.applyHistory(target);
  }

  /**
   * 把正文直接换成历史里的某一段。
   *
   * 刻意**不走 `persist()`**：它会把「写入前的正文」再压进撤销栈，于是撤销
   * 之后按重做、再按撤销会在两步之间来回打转且栈越来越长。这里只写盘 + 重解析，
   * 历史栈由 `undo()` / `redo()` 自己维护。
   */
  private applyHistory(body: string): void {
    NoteStore.instance.saveNote(this.note, body);
    this.reparse(body);
    this.touched = true;
    this.onChanged();
    this.syncHistoryFlags();
  }

  // ------------------------------------------------------------- 模式 / AI

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

  /**
   * 简单 / 分块 模式切换。
   *
   * ## 为什么写回 `SettingsStore`
   *
   * 这个开关在设置页也有一行（设置 › 编辑体验）。两处若各存各的，设置页会显示
   * 「分块」而这里实际是简单模式，用户永远不知道哪个是真的。所以**这一处改动
   * 立刻持久化**，设置页下次读到的就是同一个值。
   *
   * ## 为什么切换前必须提交草稿
   *
   * 分块 → 简单时，正在编辑的那一块要交给整篇输入接管。不先提交，草稿就只存在
   * `editingSource` 里，切过去之后整篇输入拿到的是**没有这次改动**的正文，
   * 用户刚打的字就这么没了。
   */
  private toggleEditingMode(): void {
    const index: number = this.editingIndex;
    this.commitPending();
    this.simpleEditing = !this.simpleEditing;
    SettingsStore.instance.setSimpleEditing(this.simpleEditing);
    // 从分块切到简单：若刚才有一块在编辑，光标直接落到那一块，而不是文首——
    // 「点哪儿写哪儿」不能因为换了个模式就失效。
    if (this.simpleEditing && index >= 0) {
      this.enterWholeEditingAt(index);
    }
  }

  private toggleAiPanel(): void {
    // 展开是一次明确的状态切换，给一下重档反馈。收起不给：那是「算了」，
    // 震动会让它显得像一次成功的操作。
    if (!this.aiPanelOpen) {
      Haptics.hard();
    }
    this.aiPanelOpen = !this.aiPanelOpen;
  }

  /**
   * 跑一步 AI 动作。
   *
   * ## 为什么先把草稿提交掉
   *
   * AI 读的是 `note.body`。正在编辑的那一块还没写回正文，不提交的话，润色出来
   * 的结果里缺着用户刚打的那一段——而且拿回来一替换，那段就真丢了。
   *
   * ## 为什么结果先摆出来、不直接替换
   *
   * 一次模型调用可能改动全篇措辞。直接写回去等于把「润色」变成一次不可逆的
   * 覆盖，而用户此刻并没有逐字看过新文本。所以结果是**提案**：面板里给出全文，
   * 由用户点「替换正文」才落盘，点「复制」则只进剪贴板。
   */
  private onAiAction(action: AiAction): void {
    // 请求在飞时忽略后续点击：这时另外两项是灰的，但点中同一个按钮仍然可能触发。
    if (this.aiBusy) {
      return;
    }
    this.commitPending();
    const body: string = this.note.body.trim();
    if (body.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: '这一篇还没有内容' });
      return;
    }
    this.aiBusy = true;
    this.aiActionLabel = action.label;
    AiClient.chat(action.scenario, action.system, body).then((reply: AiReply) => {
      this.aiBusy = false;
      if (!reply.ok) {
        this.getUIContext().getPromptAction().showToast({ message: reply.message });
        return;
      }
      this.aiResult = reply.text;
      this.aiResultShown = true;
    });
  }

  /** 把 AI 结果写回正文。走 `persist()`，所以这一步可以撤销。 */
  private applyAiResult(): void {
    const next: string = this.aiResult.trim();
    this.aiResultShown = false;
    if (next.length === 0 || next === this.note.body) {
      return;
    }
    this.clearEditing();
    this.touched = true;
    this.persist(next);
    this.getUIContext().getPromptAction().showToast({ message: `已替换为${this.aiActionLabel}结果` });
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
      message: '这一段会从笔记里移除。可以用顶部的「撤销」找回，但不会再出现在回收站里。',
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
    // 区间吞掉的是「这一块 + 它后面的空行」，所以删完要补一个空行回来：
    // 否则前一块和后一块会直接贴在一起，段落会被并进上一段、列表项会被吞掉。
    // 多一个空行无害，少一个空行会改结构。
    const next: string[] = lines.slice(0, range.start).concat([''], lines.slice(range.end));
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
              lineHeight: this.lineHeight,
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
              // 顶部 64 vp 给悬浮按钮让位：正文第一行要落在按钮下沿之下，
              // 否则「返回」正好压在第一段上。滚动起来之后正文会从玻璃底下
              // 穿过——那正是想要的效果，玻璃是浮在纸面上的。
              .padding({ left: 20, right: 20, top: CONTENT_TOP_INSET, bottom: 48 })
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

        // 悬浮按钮组必须是 `Stack` 的**最后**一个子节点：叠在内容之上，
        // 但仍是正常命中的节点（默认 hitTestBehavior），所以按钮可点。
        //
        // 用 `alignContent: TopStart` + `margin` 定位，不用 `position`：
        // `position` 会把节点抽出布局流，而这里需要的是「贴着屏幕左上角」，
        // 顶部对齐 + 外边距就够，且不依赖任何百分比高度。
        //
        // 整篇输入时也要显示：整篇输入框里没有第二行可以放按钮，撤销与 AI
        // 恰恰在写作时最需要。它与悬浮返回钮之间留出 `CONTENT_TOP_INSET`
        // 同样的间距（见 `WholeDocEditor` 自己的内边距）。
        this.BackButton()

        if (this.ready) {
          this.Actions()
          if (this.aiPanelOpen) {
            this.AiPanel()
          }
        }
      }
      .width('100%')
      .height('100%')
    }
    .hideTitleBar(true)
    .bindSheet(this.aiResultShown, this.AiResultSheet(), {
      height: SheetSize.LARGE,
      dragBar: true,
      showClose: false,
      backgroundColor: $r('app.color.page_bg'),
      onDisappear: () => {
        this.aiResultShown = false;
      }
    })
    .onBackPressed(() => {
      this.goBack();
      return true;
    })
    .onReady((context: NavDestinationContext) => {
      // 点正文之外就收起选区与手柄。默认策略是「保留选中文本」，于是长按选中一段
      // 之后再点别的段落，旧选区的高亮还挂在那儿，看起来像卡住了。
      try {
        this.getUIContext().setTextSelectionClearPolicy(
          TextSelectionClearPolicy.CLEAR_SELECTED_TEXT_ON_EXTERNAL_TOUCH);
      } catch (err) {
        // 26 以下没有这个接口；收起选区只是体验问题，不能因此让整页起不来。
      }
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

  /**
   * 左上角的返回钮。
   *
   * 返回本身由 `GlassButton` 的 `.onClick` 接；外面这层 `Row` 只负责定位，
   * 同时给「若以后要在左边再加一个钮」留出成排的位置。
   */
  @Builder
  BackButton() {
    Row() {
      this.GlassButton($r('sys.symbol.chevron_left'), '返回笔记列表', () => {
        this.goBack();
      }, GATE_NONE, $r('sys.color.ohos_id_color_text_primary'))
    }
    // 只让按钮本身吃触摸，`Row` 的其余部分是透明的。
    .hitTestBehavior(HitTestMode.Transparent)
    .margin({ left: FLOAT_INSET, top: FLOAT_TOP })
  }

  /**
   * 右上角一排：撤销 / 重做 / 模式切换 / AI。
   *
   * 顺序按「用到的频率 × 靠近拇指的程度」排：撤销最常用，放在最左边（离拇指
   * 最近的那一头），AI 最不常用且会弹出面板，放在最右、离正文最远。
   */
  @Builder
  Actions() {
    Row({ space: FLOAT_GAP }) {
      this.GlassButton($r('sys.symbol.undo'), '撤销', () => {
        this.undo();
      }, GATE_UNDO, $r('sys.color.ohos_id_color_text_primary'))

      this.GlassButton($r('sys.symbol.redo'), '重做', () => {
        this.redo();
      }, GATE_REDO, $r('sys.color.ohos_id_color_text_primary'))

      // 模式按钮是**状态**，不是动作：它显示当前激活的是哪一档，所以做成一个
      // 带文字的胶囊（强调色浅底 + 强调色文字），而不是和撤销/重做一样的圆钮。
      // 圆钮在这里会被读成「点一下执行某个动作」，用户看不出自己现在在哪一档。
      this.ModeButton()

      this.GlassButton($r('sys.symbol.wand_and_stars'),
        this.aiPanelOpen ? 'AI 功能，已展开' : 'AI 功能', () => {
          this.toggleAiPanel();
        }, GATE_NONE, this.aiPanelOpen ? this.accentColor : $r('sys.color.ohos_id_color_text_primary'))
    }
    .alignItems(VerticalAlign.Center)
    // 右对齐：`Stack` 的 `alignContent` 是 TopStart，所以这一排若只靠 `margin`
    // 就得知道屏幕宽度才能算出 x。让 `Row` 自己撑满宽度并 `FlexAlign.End`，
    // 右边的 16 vp 就永远落在屏幕边缘，与「返回」的左边距对称。
    .width('100%')
    .justifyContent(FlexAlign.End)
    .padding({ right: FLOAT_INSET })
    .margin({ top: FLOAT_TOP })
    // 只有按钮本身要接点击，整条空白带不该挡住正文。
    .hitTestBehavior(HitTestMode.Transparent)
  }

  /**
   * 模式切换：一个显示**当前档位**的胶囊（而不是一个圆钮）。
   *
   * 圆钮的问题不是「看不出来能不能点」，而是看不出**现在在哪一档**：图标与底色
   * 都在强调色和正文色之间切换，两种状态的差别只有一个字的色相，用户点完只
   * 得到「好像亮了一下」。这里直接写上档位名（分块 / 简单），并把当前档位画成
   * 强调色浅底 + 强调色文字——这是本应用里「已选中」的固定说法（筛选条、
   * 分段控件、标签胶囊都用同一套），不需要再学一遍。
   *
   * 名字是**当前档位**而不是「点一下会变成什么」：按钮读的是状态，不是动作。
   */
  @Builder
  ModeButton() {
    Row({ space: 5 }) {
      SymbolGlyph(this.simpleEditing ? $r('sys.symbol.doc_plaintext') : $r('sys.symbol.square_grid_2x2'))
        .fontSize(15)
        .fontColor([this.accentColor])
      Text(this.simpleEditing ? '简单' : '分块')
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.accentColor)
        .maxLines(1)
    }
    .height(FLOAT_HIT)
    .padding({ left: 12, right: 12 })
    .borderRadius(FLOAT_HIT / 2)
    .backgroundColor(this.accentChipColor())
    .backgroundEffect({ radius: 18, saturation: 1.6, brightness: 1.04, color: $r('app.color.glass_tint') })
    .border({ width: 1, color: $r('app.color.glass_border') })
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
    .onClick(() => {
      this.toggleEditingMode();
    })
    .accessibilityText(this.simpleEditing ? '编辑模式：简单，点按切换为分块' : '编辑模式：分块，点按切换为简单')
  }

  /**
   * AI 面板：AI 钮下方竖排三个胶囊，右对齐。
   *
   * 点其中一项时**面板不收起**：请求可能要等十几秒，收起面板会让「点没点上」
   * 变成一个谜；进度直接显示在被点的那一项上（转圈 + 「翻译中…」），其余两项
   * 变淡且不可点。这样「在做哪一步」和「还能不能点别的」都是眼睛能看出来的。
   *
   * 面板与按钮组共用同一层 `Stack`，同样浮在正文之上；展开时顶端由
   * `FLOAT_TOP + FLOAT_HIT + FLOAT_GAP` 推出，正好落在按钮排下面。
   */
  @Builder
  AiPanel() {
    Column({ space: FLOAT_GAP }) {
      ForEach(AI_ACTIONS, (action: AiAction) => {
        this.AiPill(action)
      }, (action: AiAction) => action.label)
    }
    .alignItems(HorizontalAlign.End)
    .width('100%')
    .justifyContent(FlexAlign.End)
    .padding({ right: FLOAT_INSET })
    .margin({ top: FLOAT_TOP + FLOAT_HIT + FLOAT_GAP })
    .hitTestBehavior(HitTestMode.Transparent)
  }

  /**
   * 一项 AI 动作（图标 + 文字胶囊）。
   *
   * 状态一律在**构建体内部**读（`isBusyFor` 这类方法），不靠参数传进来——
   * `@Builder` 的参数按值传、只在调用处求值一次，传进来的布尔值不会随状态刷新
   * （撤销钮上已经踩过一次，见 `GATE_UNDO`）。
   */
  @Builder
  AiPill(action: AiAction) {
    Row() {
      Row({ space: 6 }) {
        if (this.isBusyFor(action)) {
          LoadingProgress()
            .width(15)
            .height(15)
            .color($r('sys.color.ohos_id_color_text_primary'))
        } else {
          SymbolGlyph(action.icon)
            .fontSize(15)
            .fontColor([$r('sys.color.ohos_id_color_text_primary')])
        }
        Text(this.isBusyFor(action) ? `${action.label}中…` : action.label)
          .fontSize(13)
          .fontColor($r('sys.color.ohos_id_color_text_primary'))
          .maxLines(1)
      }
      .height(FLOAT_HIT)
      .padding({ left: 14, right: 14 })
      .borderRadius(FLOAT_HIT / 2)
      // 与圆钮同一套玻璃：模糊 + 上缘高光 + 细边。胶囊的圆角半径取半个高度，
      // 所以它和圆钮一样是「材质自己画出的形状」，不需要 `clipShape`。
      .backgroundEffect({ radius: 18, saturation: 1.6, brightness: 1.04, color: $r('app.color.glass_tint') })
      .border({ width: 1, color: $r('app.color.glass_border') })
      // 正在跑的那一项保持全不透明（它是主角），其余两项变淡表示「暂时不可点」。
      // `enabled(false)` 才是「不可点」本身：只靠 `onAiAction` 里的 `aiBusy` 早退，
      // 点击仍然会被吃掉、按钮仍然会给出按下的反馈，看着像点了没反应。
      .opacity(this.aiBusy && !this.isBusyFor(action) ? 0.4 : 1)
      .enabled(!this.aiBusy)
      .onClick(() => {
        this.onAiAction(action);
      })
      .accessibilityText(this.isBusyFor(action) ? `${action.label}进行中` : action.label)
    }
    .hitTestBehavior(HitTestMode.Transparent)
  }

  /** 这一项是不是当前正在请求的那一项。 */
  private isBusyFor(action: AiAction): boolean {
    return this.aiBusy && this.aiActionLabel === action.label;
  }

  /** 强调色的浅底（用于次级按钮）。`#RRGGBB` → `#AARRGGBB`。 */
  private accentChipColor(): string {
    const alpha: number = this.dark ? 0.24 : 0.12;
    const a: string = Math.round(alpha * 255).toString(16).padStart(2, '0').toUpperCase();
    if (this.accentColor.length === 7 && this.accentColor.startsWith('#')) {
      return `#${a}${this.accentColor.substring(1)}`;
    }
    return this.accentColor;
  }

  /** 把结果放进剪贴板。 */
  private copyAiResult(): void {
    if (this.aiResult.length === 0) {
      return;
    }
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.aiResult);
    pasteboard.getSystemPasteboard().setData(data).then(() => {
      this.getUIContext().getPromptAction().showToast({ message: '已复制' });
    }).catch((error: BusinessError) => {
      hilog.warn(DOMAIN, 'ReaderPage', 'copy failed: %{public}d', error.code);
    });
  }

  /**
   * AI 结果面板。
   *
   * 三段：标题行（动作名 + 取消）、全文预览（可滚动、可选中复制）、底部两个动作。
   * 预览是**纯文本**而不是渲染后的 Markdown：用户此刻在核对「模型改了什么」，
   * 排版会把 `**` 藏起来，而改动往往正是出在标记上。
   */
  @Builder
  AiResultSheet() {
    Column({ space: 16 }) {
      Row() {
        Text(`${this.aiActionLabel}结果`)
          .fontSize(20)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        Blank()
        Text('取消')
          .fontSize(16)
          .fontColor($r('app.color.text_secondary'))
          .padding({ left: 12, right: 4, top: 6, bottom: 6 })
          .onClick(() => {
            this.aiResultShown = false;
          })
          .accessibilityText('放弃这次 AI 结果')
      }
      .width('100%')

      Text('下面是模型给出的全文。替换之后仍然可以撤销。')
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')

      Scroll() {
        Text(this.aiResult)
          .fontSize(14)
          .lineHeight(22)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
          .copyOption(CopyOptions.LocalDevice)
          .textSelectable(TextSelectableMode.SELECTABLE_UNFOCUSABLE)
      }
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.TopStart)
      .scrollBar(BarState.Auto)
      .padding(12)
      .borderRadius(14)
      .backgroundColor($r('app.color.card_bg'))

      Row({ space: 10 }) {
        Text('复制')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.accentColor)
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .height(46)
          .borderRadius(23)
          .backgroundColor(this.accentChipColor())
          .onClick(() => {
            this.copyAiResult();
          })
          .accessibilityText('复制结果')
        Text('替换正文')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .height(46)
          .borderRadius(23)
          .backgroundColor(this.accentColor)
          .onClick(() => {
            this.applyAiResult();
          })
          .accessibilityText('用结果替换正文')
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 40 vp 圆形玻璃按钮。
   *
   * ## 为什么第四个参数是 `gate` 而不是 `dimmed: boolean`
   *
   * `@Builder` 的参数按值传：`this.GlassButton(..., !this.canUndo, ...)` 只在
   * 调用处求值一次，`@Local canUndo` 的读取不构成被构建节点的依赖。实测表现是
   * 「写完一段，撤销钮仍是灰的，点了也没反应」——按钮永远停在第一次构建时的状态。
   *
   * 所以传的是**哪一档开关**（`GATE_UNDO` / `GATE_REDO` / `GATE_NONE`），由
   * `gateDim()` 在构建体内部读 `canUndo` / `canRedo`，依赖才成立。
   *
   * 为什么不用 `.enabled(false)`：它会把整个节点（包括 `backgroundEffect` 的
   * 玻璃底和边框）一起按系统禁用色灰掉，得到的是一个灰饼而不是一个「暂时没用」
   * 的玻璃钮。这里只降透明度，并让 `onClick` 直接返回。
   *
   * `tint` / `gate` 都写成**必填**：`@Builder` 的参数在这个工具链上不认可选形参
   * （`Expected 4-5 arguments`），缺一个就要在调用处补 `undefined`，反而更容易漏。
   *
   * 圆角必须走 `borderRadius(FLOAT_HIT / 2)`，**不能**用 `clipShape(CircleShape)`：
   * 材质层按节点自己的圆角画，`clipShape` 只裁绘制，四个直边会露成亮弧
   * （AGENTS.md 里记过这条）。
   */
  @Builder
  GlassButton(icon: Resource, label: string, onTap: () => void, gate: number, tint: ResourceColor) {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 180,
          colors: [[$r('app.color.glass_hi'), 0.0], ['#00FFFFFF', 0.62]]
        })
      SymbolGlyph(icon)
        .fontSize(18)
        .fontColor([tint])
    }
    .width(FLOAT_HIT)
    .height(FLOAT_HIT)
    .borderRadius(FLOAT_HIT / 2)
    .backgroundEffect({ radius: 18, saturation: 1.6, brightness: 1.04, color: $r('app.color.glass_tint') })
    .border({ width: 1, color: $r('app.color.glass_border') })
    .clip(true)
    .opacity(this.gateDim(gate) ? 0.38 : 1)
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
    .onClick(() => {
      if (this.gateDim(gate)) {
        return;
      }
      onTap();
    })
    .accessibilityText(label)
  }

  private gateDim(gate: number): boolean {
    if (gate === GATE_UNDO) {
      return !this.canUndo;
    }
    if (gate === GATE_REDO) {
      return !this.canRedo;
    }
    return false;
  }

  /**
   * 正文一直处于可编辑状态（点哪块改哪块），行内 `Span` 的点击被用来「选中这一块」，
   * 所以链接不再是点击目标——与 Typora 的取舍一致：编辑态里点文字是放光标，
   * 不是打开网址。等接入「打开链接」的显式入口（长按菜单或顶部胶囊）再补。
   */
}
