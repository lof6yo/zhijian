import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { display, LengthMetrics, uiMaterial } from '@kit.ArkUI';
import { deviceInfo, BusinessError, systemDateTime } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { WindowService } from '../common/WindowService';
import { Toast } from '../common/Toast';
import { Dialogs } from '../common/Dialogs';
import { RADIUS_CONTROL, FONT_BODY } from '../common/UiTokens';
import { SettingsStore } from '../services/SettingsStore';
import { Note } from '../models/Note';
import { NoteStore } from '../services/NoteStore';
import { TagStore } from '../services/TagStore';
import { NoteCard } from '../components/NoteCard';
import { CardSurface } from '../components/CardSurface';
import { MaterialLayer } from '../components/MaterialLayer';
import { EmptyState } from '../components/ui/EmptyState';
import { TrashPage } from './TrashPage';
import { ReaderPage, ReaderParam } from './ReaderPage';
import { WebDavPage } from './WebDavPage';
import { NoteTransfer, TransferResult, ExportItem } from '../services/NoteTransfer';
import { FrontmatterCodec } from '../services/Frontmatter';
import { Credentials } from '../services/Credentials';
import { SyncEngine } from '../services/SyncEngine';
import { AutoSync } from '../services/AutoSync';
import { AccentScheme, Palette, TagHeat } from '../common/Palette';
import { ContourTheme, ContourThemes, ContourInk } from '../common/ContourTheme';
import { ContourCanvas } from '../components/ContourCanvas';
import { FONT_SIZE_MAX, FONT_SIZE_MIN, CARD_CORNER,
  GEAR_ADAPTIVE, GEAR_HIGH, GEAR_LOW, GEAR_MEDIUM,
  GLASS_LEVEL_DEFAULT, GLASS_LEVEL_MAX, GLASS_LEVEL_MIN,
  LINE_HEIGHT_MAX, LINE_HEIGHT_MIN } from '../services/SettingsStore';
import { AiKey } from '../services/AiKey';
import { AiTags, TagSuggestion } from '../services/AiTags';
import {
  HdsNavigation,
  HdsNavigationTitleMode,
  HdsTabs,
  HdsTabsController,
  ScrollEffectType,
  hdsMaterial,
  HdsNavigationTitleBarOptions,
  SystemMaterialParams,
  HdsNavigationTitleBarStyle,
  HdsNavigationTitleStyle,
  HdsTitleBarContentStyle,
  ScrollEffectOptions,
  TitleBarStyleOptions,
  TitleBarContentOptions,
  HdsTabsFloatingStyle,
  HdsBarWidthRangeOptions,
  HdsTabsBackgroundStyle,
  HdsAnimationMode,
  HideMode
} from '@kit.UIDesignKit';

/**
 * HDS (`@kit.UIDesignKit`) requires 6.1.0 / API 23 for the floating tab bar and
 * immersive material. Below that the shell falls back to a plain pinned `Tabs`
 * with a hand-drawn bar, so the app must never touch the HDS path unguarded.
 */
const HDS_MIN_API: number = 23;

/** Stable id for the notes search field so the title-bar action can focus it. */
const SEARCH_INPUT_ID: string = 'notesSearchInput';

/**
 * Height of the HDS title bar's bottom band — the home of 筛选条 / 排序条.
 *
 * 34 vp capsule + 8 vp air above and below. It is a **fixed** number rather than
 * content-derived because the same value has to be added to the page's top
 * inset (`titleBandHeight`), and the two must never drift: HDS sizes the band
 * from this option, the page reserves the same amount itself.
 */
const BOTTOM_BUILDER_HEIGHT: number = 50;

/** Height of the `stackBuilder` row (title + 搜索 / 新建 buttons). */
const TITLE_ROW_HEIGHT: number = 56;

/**
 * 筛选带（`bottomBuilder`）收放的三段时长（ms）。
 *
 * 收起：控件淡出（`BAND_FADE_MS`）→ 留白与结构一起收（`BAND_CLOSE_MS`）。
 * 展开：留白撑开（`BAND_OPEN_MS`）→ 挂上这一带 → 控件淡入（`BAND_FADE_MS`）。
 *
 * 收起时两者能同时改、展开时不能，原因见 `syncBand()`：结构**摘掉**不影响 padding
 * 的插值，结构**插入**会让 `animateTo` 把 padding 重算成终值。
 *
 * 数值与 `setChromeHidden()` 是同一种节奏（收 300 / 展 220，`FastOutSlowIn`）：
 * 整段收起 ≈ 320 ms，展开 ≈ 340 ms。
 */
const BAND_FADE_MS: number = 140;
const BAND_CLOSE_MS: number = 180;
const BAND_OPEN_MS: number = 200;

/**
 * 滚动内容在图顶边缘的渐隐长度（vp）。
 *
 * 顶栏收起后网格的上边界就在状态栏下沿，滚到那里的卡片会被裁成一条直线（实测
 * 格边一次跳 20 个色阶）。40 vp 够让一整排卡片的高光边缘消掉——默认的 32 仍读
 * 得出边界，而再长就开始吃掉卡片标题。
 */
const CHROME_FADE: number = 40;

const DOMAIN: number = 0x0000;
const TAG: string = 'HMStart';

/**
 * Which setting a `SegmentButton` writes. Numeric discriminants (not booleans)
 * because the settings page has three independent segmented rows and a boolean
 * pair would need a precedence rule.
 */
const SEG_THEME: number = 0;
const SEG_GLASS: number = 1;
/** 编辑体验：0 = 简单（整篇输入），1 = 分块。 */
const SEG_EDIT: number = 2;

/**
 * `.background(builder)` 的参数必须是**显式类型**的对象：ArkTS 拒绝内联对象
 * 字面量（`arkts-no-untyped-obj-literals`），而解析失败会连锁污染其后所有属性。
 */
const CARD_BG_OPTIONS: BackgroundOptions = { align: Alignment.Center };

/**
 * 搜索查询里的一片：要匹配的文本，以及它是不是排除项（`-词`）。
 *
 * 用一个类而不是内联对象字面量，因为 ArkTS 不允许无类型对象字面量，而为一个
 * 两字段的结构专门写 interface 在这里不划算——它是纯粹的内部数据。
 */
class SearchToken {
  text: string = '';
  negated: boolean = false;

  constructor(text: string, negated: boolean) {
    this.text = text;
    this.negated = negated;
  }
}

@Entry
@ComponentV2
struct Index {
  @Local selectedTab: number = 0;
  @Local query: string = '';
  /**
   * The title bar carries one compact search *button*; tapping it expands that
   * slot into a real rounded search field in place (Cube behaviour). A second
   * always-visible search box under the title duplicated the same affordance and
   * cost a full row of vertical space.
   */
  @Local searchExpanded: boolean = false;
  @Local filterMode: number = 0;
  @Local sortMode: number = 0;
  /**
   * 排序方向：false = 升序，true = 降序。
   *
   * 与标签页的 `tagSortDesc` 是同一套语义，但**分成两个字段**：两个页面的排序
   * 是各自的选择，在笔记页切到「按标题降序」不该顺手把标签页也翻过来。
   */
  @Local sortDesc: boolean = true;
  /**
   * 多选态：是否在多选中、以及勾了哪些 id。
   *
   * `selectedIds` 是 `@Local` 数组，所以**只能整体赋值**（`concat`/`filter`），
   * `push` 不会重绘。
   */
  @Local selecting: boolean = false;
  @Local selectedIds: string[] = [];
  @Local listVersion: number = 0;
  @Local notesSnapshot: Note[] = [];
  /**
   * 搜索是否已经扩展到已归档的笔记。
   *
   * 默认不扩展：搜索首先是「找我记得的那条笔记」，已归档的东西已经被用户主动收
   * 起来过一次，混进结果里等于每次搜索都要重新翻一遍旧账。命中数在结果底部提示，
   * 用户点一下才展开——这一步是显式的，和「点开已归档」是同一个决定。
   */
  @Local includeArchived: boolean = false;
  /**
   * 标签名单的快照。
   *
   * 与 `notesSnapshot` 同理：`this.store.tags` 是普通单例的字段，改了不会触发重绘，
   * 所以标签增删改之后必须显式刷新这份快照。
   */
  @Local tagsSnapshot: string[] = [];
  @Local themeMode: number = 0;
  /**
   * 背景主题下标（`ContourThemes.all` 的顺序）。
   *
   * 这是**外观里唯一的一档色相选择**：底色、地形几何、强调色全部由它派生。
   * 强调色没有独立的 `@Local`——有的话就有两个真实来源，切换主题之后旧值还
   * 挂着，界面会出现「沙海的褐色背景 + 黄山的蓝按钮」。派生点在 `scheme()`。
   */
  @Local backdropTheme: number = 0;
  @Local fontSize: number = 17;
  @Local lineHeight: number = 175;
  /**
   * Immersive glass strength gear (0 restrained / 1 reference / 2 deepest).
   * Persisted by `SettingsStore` and read through the gear tables below, so the
   * whole UI changes depth together instead of each surface drifting.
   */
  @Local glassLevel: number = GLASS_LEVEL_DEFAULT;
  /** 编辑体验：true = 简单（整篇输入），false = 分块。默认简单。 */
  @Local simpleEditing: boolean = false;
  /** 格式按钮条，默认关。 */
  @Local showFormatBar: boolean = false;
  /** 标签页排序依据：0 = 名称，1 = 笔记数量。 */
  @Local tagSortKey: number = 0;
  /** 标签页排序方向：false = 升序，true = 降序。 */
  @Local tagSortDesc: boolean = false;
  /** 标签页筛选：0 = 全部，1 = 只在用的（名录里建了但没人用的不算）。 */
  @Local tagFilter: number = 0;
  /** 新建 / 修改标签名的输入面板是否打开。 */
  @Local tagNameShown: boolean = false;
  /** 0 = 新建，1 = 修改。 */
  @Local tagNameMode: number = 0;
  /** 修改时的原标签名。 */
  @Local tagNameTarget: string = '';
  /** 输入框里的标签名。 */
  @Local tagNameInput: string = '';
  /**
   * Id of the note whose 标签 sheet is open, and the working copy of its tags.
   *
   * The tags live in a `@Local` array rather than being written straight into the
   * `Note`: `Note` is `@ObservedV2`, so mutating it mid-edit would repaint the
   * grid behind the sheet on every keystroke and — worse — a cancelled sheet
   * would have already changed the note. The array is committed in one call to
   * `NoteStore.setTags()` when the user confirms.
   */
  @Local tagEditNoteId: string = '';
  @Local tagEditTags: string[] = [];
  @Local tagDraft: string = '';
  @Local tagSheetShown: boolean = false;
  @Local pathStack: NavPathStack = new NavPathStack();
  /**
   * 顶栏与悬浮页签栏是否已让位（内容向上滑动时收起，向下滑动时恢复）。
   *
   * 两条 chrome 由一个状态驱动，所以它们**同时**收起、同时回来：一半收一半
   * 不收的界面看起来像卡住了。
   */
  @Local chromeHidden: boolean = false;
  /**
   * 筛选带里那两条胶囊的不透明度档位：`true` = 正在淡出 / 已淡出。
   *
   * 这是三个状态里唯一走纯属性动画的一个（`opacity`），所以它决定「控件怎么走」。
   */
  @Local bandFading: boolean = false;
  /**
   * 筛选带是否**在结构上存在**（决定 `bottomBuilder` 给不给）。
   *
   * ## 为什么必须与页面留白分开
   *
   * `bottomBuilder` 是交给 HDS 的**构建参数**，挂上 / 摘掉都是瞬时的，`animateTo`
   * 对结构无效。早先把「结构摘掉」和「留白归零」写成同一个布尔，收起方向看着是平滑的
   * （节点先没了，padding 还在插值），但**展开方向一帧跳 50 vp**——实测 `外观` 从
   * 419 px 直接到 313 px 再回到 435 px：结构插入时把 padding 重算成了终值，
   * 插值被跳过。
   *
   * 所以结构只在**两端**切换，而且切换时留白已是 0（收起）或仍是 0（展开），
   * 那一刻画面完全一样，看不见它跳。
   */
  @Local bandShown: boolean = true;
  /**
   * 页面顶部留白里属于筛选带的那一段（vp），`0…BOTTOM_BUILDER_HEIGHT`。
   *
   * 它才是「内容往下让」的那段距离，是一个普通数字，`animateTo` 能逐帧插值。
   * `titleBandHeight()` 读它，于是笔记网格、标签列表、设置页三者一起平移——
   * 而它们本来就在同一条 50 vp 上，不可能有一处先到。
   */
  @Local bandInset: number = BOTTOM_BUILDER_HEIGHT;
  /**
   * 带子里画的是**哪个页签**的筛选条。
   *
   * 不能直接用 `selectedTab`：切到设置页的那一刻 `selectedTab` 已经是 2，而带子
   * 还要淡出 140 ms。照 `selectedTab` 画，这 140 ms 里画出来的是标签页的两条
   * 「全部 / 在用」「名称 / 数量」——实测抓到的中间帧就是这样，笔记页的筛选条在
   * 淡出途中换成了另一页的控件，比直接消失更奇怪。
   *
   * 所以它是**带子自己的页签**：收起期间保持原样，只在展开的起点切到目标页签。
   */
  @Local bandTab: number = 0;
  /** 收起 / 展开的排队定时器（-1 = 没在跑）。 */
  private bandTimer: number = -1;
  /** 上一次采样到的滚动位置（vp），用来算方向。 */
  private lastScrollY: number = 0;
  /** 同向滚动的累积量；抖一下就翻状态会让界面在滑动时闪烁。 */
  private scrollAccum: number = 0;
  /** 当前滚动方向：1 = 内容被往上推（看后面的内容），-1 = 往回翻。 */
  private scrollDir: number = 1;
  /**
   * 下一次滚动只当基准、不算位移。
   *
   * 三个页签是**三条独立的滚动轴**，而 `lastScrollY` 只有一份。切回一个已经滑到
   * 中段的页签时，它下一次 `onDidScroll` 的 yOffset 是 500 而上一次记的是 0——
   * 那 500 vp 会被当成「用户正在猛推」，顶栏在手指还没动的时候就收起来了。
   * 所以每次 `restoreChrome()` 之后先让第一条事件把基准种上。
   */
  private scrollSeed: boolean = true;
  /** 搜索历史快照，新的在前。 */
  @Local searchHistory: string[] = [];
  /** AI 设置组的草稿：endpoint 与三个场景的模型名。 */
  @Local aiEndpointDraft: string = '';
  @Local aiModelDraft0: string = '';
  @Local aiModelDraft1: string = '';
  @Local aiModelDraft2: string = '';
  /** 密钥输入框草稿。空串表示「不修改」，与 WebDAV 密码同一套约定。 */
  @Local aiKeyDraft: string = '';
  /** 是否已存过密钥。只用来决定占位文案，从不回填密钥本身。 */
  @Local aiKeyPresent: boolean = false;
  /**
   * AI 洞见（左重划）正在跑。
   *
   * 请求可能等十几秒，而这一次是**在卡片上手势触发的**——手指已经离开，卡片也已
   * 回弹到原位，没有任何东西还停在那里表示「在做事」。所以这一页自己给一条浮在
   * 底部的进度胶囊（`InsightPill`），而不是让用户对着一张看不出变化的网格等。
   */
  @Local insightBusy: boolean = false;
  /** 正在处理的那一篇的标题，用于进度胶囊里点明「在做哪一篇」。 */
  @Local insightTarget: string = '';
  /**
   * Snapshot of `syncFinishedAt`, and of the state word the 设置 › WebDAV 同步
   * row renders.
   *
   * `SettingsStore` is a plain singleton, not `@ObservedV2`, so a `@Builder` that
   * reads it directly is not guaranteed to re-render when a `NavDestination`
   * pops — the same trap the note list hit (see `refreshList`). Copying into
   * `@Local` fields and reassigning them in the `didShow` interception is what
   * makes the row update the moment the user returns from `WebDavPage`.
   *
   * Copying alone is not enough: the row must also *read* these fields inside a
   * parameter-less builder. See `WebDavRow()` — passing
   * `this.davRowSubtitle()` into `SettingRow(...)` registered the read against
   * the call site, not the built nodes, so the text never refreshed on device.
   */
  @Local davLastSync: number = 0;
  @Local davStateLabel: string = '未配置';
  private store: NoteStore = NoteStore.instance;

  // One scroller per tab: each tab keeps its own scroll position, which is a
  // requirement of the floating-bar interaction (the bar is bound to the
  // active tab's scroller).
  private notesScroller: Scroller = new Scroller();
  private tagsScroller: Scroller = new Scroller();
  private settingsScroller: Scroller = new Scroller();
  private hdsTabs: HdsTabsController = new HdsTabsController();

  /**
   * Capability gate. `hdsMaterial.getSystemMaterialTypes()` returns the
   * materials the *device* can actually render. IMMERSIVE means the full
   * light-sensing material is available; without it we request SMOOTH so a
   * low-end device does not spend its frame budget on an effect it cannot
   * afford. Both are still HDS — only the level changes.
   */
  private hdsSupported: boolean = false;
  private immersiveSupported: boolean = false;
  /**
   * The device's own material tier from `uiMaterial.getGlobalMaterialLevel()`
   * (0 = 高算力, 1 = 中算力, 2 = 低算力). Read-only and purely informational: it is
   * what `ADAPTIVE` defers to, so showing it makes the 自适应 gear meaningful
   * instead of a black box. `-1` means "not probed".
   */
  private deviceTier: number = -1;

  private readonly SIDE_INSET: number = 16;

  /**
   * 顶栏让开之后页面内容的顶部留白 = 状态栏 + 8 vp。
   *
   * **`padding` 从窗口顶端起算，尽管内容根节点自己是从状态栏下沿开始的**
   * （`ui_dump`：`root` 在 `[0,117]`）。`ignoreLayoutSafeArea` 把布局铺进安全区
   * 之后，安全区内的内边距按窗口坐标解析，所以只留 8 vp 会让内容压在时钟上——
   * 实测过「全部/收藏/归档」与时间重叠。
   *
   * 与 `titleBandHeight()` 里的状态栏项是同一个道理、同一个数（39 vp），不是重复
   * 计算：那个算「标题栏下沿在哪」，这个算「收起后内容从哪开始」。
   * 反证：`titleBandHeight()` 去掉该项后网格从 459 px 掉到 342 px，正好 117 px。
   */
  private chromeTopInset(): number {
    return WindowService.statusBarHeightVp() + 8;
  }

  /**
   * 卡片、设置分组卡片与提示条共用的圆角（vp）。
   *
   * 与筛选条 / 排序条那条胶囊是**同一个数**：外壳 34 vp 高、半径 17；选中 chip
   * 28 vp 高、半径 14。卡片也用 17，两种控件才是同一套形状语言。原来那档
   * 8–36 的滑块只影响「卡片有多圆」——既不是密度也不是可读性，调它得不到任何
   * 东西，却让卡片弧度在每台机器上都可能不同，永远对不上胶囊。
   */
  private readonly cardCorner: number = CARD_CORNER;

  aboutToAppear(): void {
    this.themeMode = SettingsStore.instance.themeMode;
    this.backdropTheme = SettingsStore.instance.backdropTheme;
    this.fontSize = SettingsStore.instance.editorFontSize;
    this.lineHeight = SettingsStore.instance.editorLineHeight;
    this.glassLevel = SettingsStore.instance.glassLevel;
    this.simpleEditing = SettingsStore.instance.simpleEditing;
    this.showFormatBar = SettingsStore.instance.formatBar;
    this.searchHistory = SettingsStore.instance.searchHistory
      .split('\n')
      .filter((item: string) => item.trim().length > 0);
    this.aiEndpointDraft = SettingsStore.instance.aiEndpoint;
    this.aiModelDraft0 = SettingsStore.instance.aiModelInsight;
    this.aiModelDraft1 = SettingsStore.instance.aiModelTranslate;
    this.aiModelDraft2 = SettingsStore.instance.aiModelPolish;
    this.refreshDavState();
    // 密钥只探「在不在」，永不留存明文：设置页只需要知道占位文案该写什么。
    AiKey.load().then((key: string) => {
      this.aiKeyPresent = key.length > 0;
    });

    this.hdsSupported = deviceInfo.sdkApiVersion >= HDS_MIN_API;
    if (this.hdsSupported) {
      const types: Array<hdsMaterial.MaterialType> = hdsMaterial.getSystemMaterialTypes();
      this.immersiveSupported = types.indexOf(hdsMaterial.MaterialType.IMMERSIVE) >= 0;
    }
    // The tier behind the 自适应 gear. `uiMaterial` is API 26, so it is gated on
    // the same `hdsSupported` probe plus its own support check rather than
    // assumed — the value is only ever displayed, never used to drive layout.
    if (this.hdsSupported) {
      try {
        if (uiMaterial.isImmersiveMaterialSupported()) {
          this.deviceTier = uiMaterial.getGlobalMaterialLevel();
        }
      } catch (err) {
        const error = err as BusinessError;
        hilog.warn(DOMAIN, TAG, 'material level probe failed: %{public}d', error.code);
      }
    }

    // The ability applies the stored colour mode during `onCreate`, but the
    // window's system bars are re-initialised when the stage loads content, so
    // the stored light/dark choice has to be re-asserted once the page exists.
    this.refreshSystemBars();

    this.bindStackRefresh();
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.store.init(context.filesDir);
    this.refreshList();
    this.bindTabScrollers();
    this.hydrateSync();
    this.installAutoSync();
  }

  /** 页面销毁时把筛选带的排队定时器收掉，否则它会抱着整页引用继续跑。 */
  aboutToDisappear(): void {
    if (this.bandTimer >= 0) {
      clearTimeout(this.bandTimer);
      this.bandTimer = -1;
    }
  }

  private bindTabScrollers(): void {
    if (!this.hdsSupported) {
      return;
    }
    this.hdsTabs.bindScroller(0, this.notesScroller);
    this.hdsTabs.bindScroller(1, this.tagsScroller);
    this.hdsTabs.bindScroller(2, this.settingsScroller);
  }

  /**
   * Seeds `SyncEngine.config` from the stored settings once per launch.
   *
   * The password is fetched from Asset Store Kit asynchronously, so a sync can
   * never start before this resolves — the settings page awaits its own
   * `saveSettings()` round trip and therefore re-reads the secret there. This
   * call exists so the 设置 row can report 已配置 without the page being opened,
   * and so a future background sync has credentials available.
   */
  private hydrateSync(): void {
    const settings = SettingsStore.instance;
    if (settings.davUrl.length === 0) {
      return;
    }
    Credentials.loadPassword()
      .then((secret: string) => {
        SyncEngine.applySettings(settings, secret);
        if (secret.length === 0) {
          hilog.warn(DOMAIN, TAG, 'webdav configured without a stored password');
        }
      })
      .catch((error: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'credential hydrate failed: %{public}d', error.code);
      });
  }

  /**
   * Material pair used by every HDS surface (title bar + floating tab bar).
   * IMMERSIVE is the real "immersive light-sensation" material; the *level* is
   * the user's gear, translated to the platform enum.
   *
   * `ADAPTIVE` is the default and the officially recommended value: the platform
   * docs warn that pinning `EXQUISITE` or `GENTLE` on a low-power device "可能造成
   * 卡顿和发热", because the level is really a device-compute tier rather than a
   * taste knob. The explicit gears exist so a user can override deliberately, and
   * the settings row shows the device's own tier so that override is informed.
   *
   * Devices without IMMERSIVE fall back to ADAPTIVE/SMOOTH, so the surface
   * degrades by level rather than disappearing.
   */
  private materialType(): hdsMaterial.MaterialType {
    return this.immersiveSupported
      ? hdsMaterial.MaterialType.IMMERSIVE
      : hdsMaterial.MaterialType.ADAPTIVE;
  }

  private materialLevel(): hdsMaterial.MaterialLevel {
    if (!this.immersiveSupported) {
      return hdsMaterial.MaterialLevel.SMOOTH;
    }
    const levels: hdsMaterial.MaterialLevel[] = [
      hdsMaterial.MaterialLevel.ADAPTIVE,
      hdsMaterial.MaterialLevel.EXQUISITE,
      hdsMaterial.MaterialLevel.GENTLE,
      hdsMaterial.MaterialLevel.SMOOTH
    ];
    return levels[this.glassIndex()];
  }

  // ---------------------------------------------------------------- data

  private refreshList(): void {
    this.notesSnapshot = [...this.store.notes];
    // 标签名单同样要一份快照：`this.store.tags` 是普通单例的字段，改了不会重绘。
    this.tagsSnapshot = TagStore.instance.knownTags(this.store.tags);
    this.listVersion++;
    // 删掉最后一个标签时标签页的筛选带要收起来，而这不是一次页签切换——
    // 目标高度跟着 `tagsSnapshot` 变，所以这里也要跟上。
    this.syncBand();
  }

  // ------------------------------------------------------- chrome on scroll

  /**
   * 滚动时收起 / 恢复顶栏与悬浮页签栏。
   *
   * ## 为什么两条 chrome 共用一个状态
   *
   * 「向上翻的时候把界面让出来」是一次整体的动作。顶栏收起了、页签栏还在原地，
   * 看起来不是让位，是卡住了。所以 `chromeHidden` 一个开关同时驱动两件事：
   * HDS 标题栏（`hideTitleBar`，筛选条 / 排序条在它的 `bottomBuilder` 里，跟着一起
   * 收起）与悬浮页签栏（`applyHideAnimation` / `applyShowAnimation`）。
   *
   * ## 为什么不用 HDS 自己的 `dynamicHideTitleBar`
   *
   * 那个接口按**滚动事件**自己判方向（`dynamicHideTitleBar({ hideTitleArea,
   * hideBottomBuilder, hideStatusBar })`），而这页要让的是「顶栏 + 页签栏」两件
   * 事、并且由同一个开关驱动。用它就得把页签栏另挂一套判定，两套阈值必然错拍，
   * 于是出现「标题栏走了、页签栏还赖着」的半截状态。要么整套动，要么整套不动，
   * 所以方向由这一页自己判定。
   *
   * ## 方向与阈值
   *
   * 位移取自传入 `Scroller` 的 `currentOffset()`，而不是 `onDidScroll` 的增量：
   * 增量的正负号在不同容器上含义不同，而「yOffset 变大 = 内容被往上推」是没有
   * 歧义的。同向累计 24 vp 才翻转状态——手指落下时的抖动与回弹都会产生反向的
   * 几 vp，直接跟着翻会让界面在滑动过程中闪烁。
   *
   * 回到顶部（yOffset ≲ 4 vp）时无条件恢复：那是「我从头再看一遍」的位置，
   * 顶栏不在就等于没有搜索框和新建按钮。
   *
   * ## 为什么收 `Scroller` 而不是写死 `notesScroller`
   *
   * 「上滑让位」是这一层外壳的行为，不是笔记网格的行为。三个页签各有自己的
   * `Scroller`（`bindScroller(i, …)` 就是为了保留各自的滚动位置），所以任何一条
   * 滚动轴都得能驱动同一套判定——否则在设置页上滑，顶栏和页签栏纹丝不动，用户
   * 会以为这一页坏了。三条轴共用一份 `lastScrollY` / `scrollAccum` 是安全的：
   * 切页签时 `restoreChrome()` 会 `scrollSeed = true`，新轴的第一条事件只种基准、
   * 不算位移，不会把「切过去时已经滑到中段」误读成一次猛推。
   */
  private handleChromeScroll(scroller: Scroller): void {
    const y: number = scroller.currentOffset().yOffset;

    // 新轴上来的第一条事件只用来对齐基准。
    if (this.scrollSeed) {
      this.scrollSeed = false;
      this.lastScrollY = y;
      this.scrollAccum = 0;
      this.scrollDir = 1;
      return;
    }

    const delta: number = y - this.lastScrollY;
    this.lastScrollY = y;

    if (y <= 4) {
      this.scrollAccum = 0;
      this.setChromeHidden(false);
      return;
    }
    // 到底之后继续同向划动，容器先给出越过边界的位移，松手再弹回来；那一段回弹在
    // `yOffset` 上就是「位置在减小」，与「用户往回翻」完全同形。
    //
    // 于是同一次上滑先收起、弹回时又把栏叫了回来，而 HDS 的展开动效在这一刻是把
    // 胶囊摊成满屏宽的那一个——实测（设置页拉到底再上滑）胶囊从 900 px 摊到 1320 px、
    // 图标放大到 1.67 倍再缩回去，读起来就是「底栏往上跑、放得特别大」。
    //
    // 到底时 `yOffset` 已经不是位置的度量：那一截既是回弹，方向判定在这里没有意义。
    // 所以到底期间不累计反向位移；离开底部之后重新种基准，回弹的余量不会
    // 被当成一次「猛推」。
    //
    // 但只能压掉「位置在减小」的那一半。内容刚过一屏的页面（标签药丸多到十来行
    // 就是这样）第一帧位移就直接落在底部，整段守卫连正方向一起吞掉，于是收起
    // 永远不触发——实测标签页上滑到底栏纹丝不动，看着就是「这一页的收起坏了」。
    // 正方向的位移这时仍然是真位移，照常累计。
    if (scroller.isAtEnd() && delta < 0) {
      this.scrollAccum = 0;
      this.scrollSeed = true;
      return;
    }
    if (delta === 0) {
      return;
    }
    const dir: number = delta > 0 ? 1 : -1;
    if (dir !== this.scrollDir) {
      this.scrollDir = dir;
      this.scrollAccum = 0;
    }
    this.scrollAccum += Math.abs(delta);
    if (this.scrollAccum < 24) {
      return;
    }
    this.scrollAccum = 0;
    this.setChromeHidden(dir > 0);
  }

  private setChromeHidden(hidden: boolean): void {
    if (hidden === this.chromeHidden) {
      return;
    }
    // 顶栏与筛选条**必须同一条时间线**。
    //
    // 这里曾经是 `chromeHidden = hidden` + 各处 `.animation({duration:200})`：
    // 标题栏由 HDS 按自己的时长收缩，而胶囊在 200 ms 就走完了，于是「顶栏还没
    // 收起，筛选和排序控件已经上移」——两条曲线各走各的，中间那一下就是顿挫。
    //
    // 现在由这一处统一驱动：`animateTo` 把胶囊的 `top` 与标题栏的显隐放进同一次
    // 状态变更里。收起的时长长于展开，并且延迟一小段——先让标题栏动起来，胶囊
    // 再跟上，看起来是「让位」而不是「抢位」。
    animateTo({
      duration: hidden ? 300 : 220,
      curve: Curve.FastOutSlowIn,
      delay: hidden ? 60 : 0
    }, () => {
      this.chromeHidden = hidden;
    });
    if (!this.hdsSupported) {
      return;
    }
    // 页签栏的显隐是 HDS 控制的（`HdsTabsFloatingStyle` 没有可见性字段，栏本身
    // 画在 HDS 里），所以只能请它播自己的收起 / 展开动效，而不是给自绘胶囊加
    // `translate`——那条自绘胶囊在 HDS 外壳里根本不参与布局。
    //
    // **两个方向都只能走 `SCROLL_ANIMATION`**，这一点踩过两次：
    //
    // - `CLICK_ANIMATION` 收起时只收标题栏，页签栏停在原地——笔记页与标签页
    //   「上滑后底栏不动」，看着就是收起失效。
    // - `CLICK_ANIMATION` 展开时**落点是错的**：实测栏位落在 `[210,2106][1110,2232]`，
    //   比常态 `[210,1980][1110,2148]` 低 126 px，高度从 56 vp 压到 42 vp，28 vp 的
    //   底部边距整个丢掉、贴到屏幕底边——画面上就是「恢复的位置不对、底栏被切了一截」。
    //   `SCROLL_ANIMATION` 展开的落点与常态逐像素一致（三页签 × 三种恢复路径都验过）。
    //
    // 唯一反对 `SCROLL_ANIMATION` 的理由曾经是「展开时把胶囊摊成满屏宽」。实测那次
    // 摊宽来自**到底回弹被误判成往回翻**（见 `handleChromeScroll` 的 `isAtEnd()`
    // 一段），与档位无关：回弹压掉之后，在底部上滑根本不会再触发展开；而正常的原位
    // 展开，连拍帧里胶囊是在原处由窄变宽，没有铺满整行的一帧。所以这里不再分方向，
    // 也不再有例外。
    const mode: HdsAnimationMode = HdsAnimationMode.SCROLL_ANIMATION;
    if (hidden) {
      this.hdsTabs.applyHideAnimation(mode);
    } else {
      this.hdsTabs.applyShowAnimation(mode);
    }
  }

  /** 切页签、进笔记页、清空搜索之后都回到「chrome 在位」的常态。 */
  private restoreChrome(): void {
    this.lastScrollY = 0;
    this.scrollAccum = 0;
    this.scrollDir = 1;
    this.scrollSeed = true;
    this.setChromeHidden(false);
  }

  // -------------------------------------------------------------- 搜索历史

  /**
   * 记一条搜索词。
   *
   * 只记**提交过**的词（回车），不记每一次按键：`onChange` 每敲一个字都会响，
   * 记下来的是「微」「微信」「微信 群」三条残句，历史列表会立刻变成垃圾。
   * 去重后放到最前，最多 8 条——超过一屏的历史需要滚动，而这一栏存在的意义
   * 是「省一次输入」，不是归档。
   */
  private rememberSearch(term: string): void {
    const cleaned: string = term.trim();
    if (cleaned.length === 0) {
      return;
    }
    const next: string[] = [cleaned];
    for (const old of this.searchHistory) {
      if (old !== cleaned && next.length < 8) {
        next.push(old);
      }
    }
    this.searchHistory = next;
    SettingsStore.instance.setSearchHistory(next.join('\n'));
  }

  private clearSearchHistory(): void {
    this.searchHistory = [];
    SettingsStore.instance.setSearchHistory('');
  }

  /**
   * 最近搜索要不要露出来。
   *
   * 三个条件缺一不可：搜索框展开着（否则这一栏会挂在正常浏览的笔记页上）、
   * 查询是空的（一旦开始打字，用户要的是结果，历史会把第一屏结果挤下去）、
   * 历史非空（第一次用这个应用的人看到的应该是笔记，不是一块空标题）。
   */
  private historyVisible(): boolean {
    return this.searchExpanded && this.query.trim().length === 0 && this.searchHistory.length > 0;
  }

  /**
   * 某一档筛选条允许哪些笔记通过。
   *
   * 归档的笔记**只在「已归档」里出现**：它是被用户主动收起来的东西，「全部」
   * 如果还带着它们，归档就只是换了个没什么区别的顺序。收藏同理——一篇收藏过的
   * 笔记归档之后又从「收藏」里冒出来，等于归档没生效。
   *
   * 唯一的例外是搜索底部的「在已归档中搜索」（`includeArchived`）：那一步由用户
   * 显式点开，语义是「我知道它被归档了，帮我翻出来」，所以只对「全部」放开。
   */
  private passesFilter(note: Note): boolean {
    if (this.filterMode === 1) {
      return note.archived;
    }
    if (note.archived && !(this.filterMode === 0 && this.includeArchived)) {
      return false;
    }
    if (this.filterMode === 2) {
      return note.favorite;
    }
    return true;
  }

  private visibleNotes(): Note[] {
    const q = this.query.trim().toLowerCase();
    const scored: Note[] = [];
    for (const note of this.notesSnapshot) {
      if (!this.passesFilter(note)) {
        continue;
      }
      if (q.length > 0 && !this.matches(note, q)) {
        continue;
      }
      scored.push(note);
    }
    this.applySort(scored);
    return scored;
  }

  /**
   * 是否有笔记命中搜索词、但因为归档被挡在结果之外。
   *
   * 只说「有没有」，不说「有多少」：用户要的是一次「去已归档里看看」的入口，
   * 不是一份统计。「还有 3 篇匹配」这种数字既占宽度，又暗示结果一共就那么几篇，
   * 而真正需要的是「那边还有，去看吗」。
   *
   * 必须复用 `matches()`：点开之后多出来的那几条要和这个判断完全一致，
   * 否则会出现「说有一篇、点开却一篇没多」。
   */
  private hasArchivedHits(): boolean {
    const q = this.query.trim().toLowerCase();
    if (q.length === 0 || this.filterMode !== 0) {
      return false;
    }
    for (const note of this.notesSnapshot) {
      if (note.archived && this.matches(note, q)) {
        return true;
      }
    }
    return false;
  }

  /**
   * 排序。
   *
   * 三种依据各自的**自然方向**不同：「最近修改」「按创建」是新的在前（降序），
   * 「按标题」是 A→Z（升序）。所以先按依据做一次基准排序，再由 `sortDesc` 决定
   * 要不要整体翻转——翻转而不是给每个比较函数写两遍，是因为三种依据的「反向」
   * 定义完全一致（把结果倒过来），写两遍迟早有一处反了。
   *
   * `sortDesc` 的默认值是 `true`，于是「最近修改」保持原来的新在前，而用户点一下
   * 「按标题」就得到 A→Z——不是 Z→A。基准方向见 `sortDefaultDesc()`。
   */
  private applySort(list: Note[]): void {
    if (this.sortMode === 1) {
      list.sort((a: Note, b: Note): number => a.title.localeCompare(b.title, 'zh-CN'));
    } else if (this.sortMode === 2) {
      list.sort((a: Note, b: Note): number => a.createdAt - b.createdAt);
    } else {
      // 最近修改。置顶那一档已经去掉，所以这里只剩时间。
      list.sort((a: Note, b: Note): number => a.updatedAt - b.updatedAt);
    }
    if (this.sortDesc) {
      list.reverse();
    }
  }

  /**
   * 某个排序依据的「自然」方向。切到这一档时用它初始化 `sortDesc`，
   * 这样每种依据第一次点开都是它最常用的那个方向。
   */
  private sortDefaultDesc(mode: number): boolean {
    // 0 最近修改 / 2 按创建：新的在前。1 按标题：A→Z。
    return mode !== 1;
  }

  /**
   * 一个搜索词是否命中这条笔记。
   *
   * ## 空格分词 + `-` 排除
   *
   * 查询先按空白切成若干 token，**全部**正向 token 都要命中（AND），任一 `-词`
   * 命中即淘汰。这是把「微信 群」写成两个词就只找同时含两者的笔记，而
   * 「会议 -周报」排除掉一整个系列——在笔记库里，「同时出现」比「任一出现」
   * 有用得多：后者用中文搜两个常见字就能返回半个库。
   *
   * 只有 `-` 后面还有字才算排除；一个孤立的 `-` 是用户在打「- [ ]」之类的东西，
   * 当作普通字符处理，否则整个查询会被解析成「什么都不排除但也不匹配」。
   *
   * 每个 token 仍然是**子串**匹配而不是分词匹配：中文没有空格可切，用户输入的
   * 一段连续汉字往往正是标题里的一段。
   */
  private matches(note: Note, query: string): boolean {
    const tokens = Index.searchTokens(query);
    if (tokens.length === 0) {
      return true;
    }
    for (const token of tokens) {
      const hit = Index.noteHits(note, token.text);
      if (token.negated ? hit : !hit) {
        return false;
      }
    }
    return true;
  }

  /** 把查询拆成「要不要命中」的 token；空查询返回空数组。 */
  private static searchTokens(query: string): SearchToken[] {
    const out: SearchToken[] = [];
    const parts = query.trim().toLowerCase().split(/\s+/);
    for (const part of parts) {
      if (part.length === 0) {
        continue;
      }
      if (part.length > 1 && part.startsWith('-')) {
        out.push(new SearchToken(part.substring(1), true));
      } else {
        out.push(new SearchToken(part, false));
      }
    }
    return out;
  }

  private static noteHits(note: Note, q: string): boolean {
    if (note.title.toLowerCase().indexOf(q) >= 0) {
      return true;
    }
    if (note.body.toLowerCase().indexOf(q) >= 0) {
      return true;
    }
    for (const tag of note.tags) {
      if (tag.toLowerCase().indexOf(q) >= 0) {
        return true;
      }
    }
    return false;
  }

  /**
   * Single refresh mechanism for every return from a NavDestination.
   * `pushPath({ onPop })` is not usable here: docs guarantee onPop only fires when
   * `pop(result)` carries a result, so a plain back press or `pop()` in
   * TrashPage silently skipped the reload and left a stale list. Navigation
   * interception `didShow` fires for every transition regardless of payload.
   */
  private bindStackRefresh(): void {
    this.pathStack.setInterception({
      didShow: (from: NavDestinationContext | NavBar, to: NavDestinationContext | NavBar,
        operation: NavigationOperation, isAnimated: boolean) => {
        // 详情页开着时不做自动同步：阅读器里可能有未提交的草稿，同步会改文件，
        // 草稿写回就会把同步下来的内容盖掉。
        AutoSync.instance.detailOpen = this.pathStack.size() > 1;
        if (operation !== NavigationOperation.POP) {
          return;
        }
        this.store.reload();
        this.refreshList();
        this.refreshDavState();
        // 从笔记页 / 回收站 / WebDAV 回来时把顶栏与页签栏请回来：它们是页面的
        // 常驻控制，不该因为「在详情页之前滑过一下」而一直缺席。
        this.restoreChrome();
      }
    });
  }

  /**
   * 装上自动同步的动作。
   *
   * 真正的「跑一次同步」放在这里而不是服务里，因为只有页面层知道同步完要刷新
   * 哪个列表。服务只管**什么时候**跑。
   */
  private installAutoSync(): void {
    const auto = AutoSync.instance;
    auto.runner = async (): Promise<boolean> => {
      const settings = SettingsStore.instance;
      if (settings.davUrl.length === 0 || settings.davUser.length === 0) {
        return false;
      }
      // 口令在 Asset Store 里，每次同步前都要取一次——它从不进偏好文件。
      const secret: string = await Credentials.loadPassword();
      if (secret.length === 0) {
        return false;
      }
      SyncEngine.applySettings(settings, secret);
      const outcome = await SyncEngine.sync(settings);
      if (outcome.ok) {
        this.store.reload();
        this.refreshList();
      }
      return outcome.ok;
    };
    auto.onDone = (ok: boolean) => {
      this.refreshDavState();
      if (!ok) {
        hilog.warn(0x0000, 'HMStart', 'auto sync failed');
      }
    };
  }

  // --------------------------------------------------------------- theme

  private systemIsDark(): boolean {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    return context.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
  }

  private activeDark(): boolean {
    if (this.themeMode === 2) {
      return true;
    }
    if (this.themeMode === 1) {
      return false;
    }
    return this.systemIsDark();
  }

  private setThemeMode(mode: number): void {
    this.themeMode = mode;
    SettingsStore.instance.setThemeMode(mode);
    WindowService.applySystemBars(this.activeDark());
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    let colorMode: ConfigurationConstant.ColorMode = ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
    if (mode === 1) {
      colorMode = ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
    } else if (mode === 2) {
      colorMode = ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    }
    context.getApplicationContext().setColorMode(colorMode);
    this.refreshSystemBars();
  }

  private refreshSystemBars(): void {
    WindowService.applySystemBars(this.activeDark());
    setTimeout(() => {
      WindowService.applySystemBars(this.activeDark());
    }, 120);
    setTimeout(() => {
      WindowService.applySystemBars(this.activeDark());
    }, 420);
  }

  /**
   * 切背景主题。所有色相都跟着它走。
   *
   * 只改 `@Local` + 持久化：底色渐变、地形几何、强调色、设置页的选中圈都读同一
   * 个 `backdropTheme`，所以一处赋值就全部跟着变，不需要通知画布（画布自己有
   * `@Monitor('themeKey')`）。强调色也在这里随之切换，因为它没有第二个来源。
   */
  private setBackdropTheme(index: number): void {
    this.backdropTheme = index;
    SettingsStore.instance.setBackdropTheme(index);
  }

  private backdrop(): ContourTheme {
    return ContourThemes.theme(this.backdropTheme);
  }

  /**
   * Applies a glass gear. Only UI state changes here — `glassEffect()`,
   * `glassSheenStop()`, `glassRimWidth()` and `materialLevel()` all read
   * `glassLevel`, so every glass surface (and the HDS tab bar's material level)
   * repaints in one go with no rebuild.
   */
  private setGlassLevel(level: number): void {
    this.glassLevel = level;
    SettingsStore.instance.setGlassLevel(level);
  }

  private setSimpleEditing(on: boolean): void {
    this.simpleEditing = on;
    SettingsStore.instance.setSimpleEditing(on);
  }

  private setFormatBar(on: boolean): void {
    this.showFormatBar = on;
    SettingsStore.instance.setFormatBar(on);
  }

  private clampLineHeight(value: number): number {
    if (value < LINE_HEIGHT_MIN) {
      return LINE_HEIGHT_MIN;
    }
    if (value > LINE_HEIGHT_MAX) {
      return LINE_HEIGHT_MAX;
    }
    return value;
  }

  /**
   * 当前强调色。
   *
   * **只有一个输入：`backdropTheme`。** 强调色由主题的 `accentKey` 派生，界面
   * 上不存在独立的色相开关，所以这里读的必须与 `backdrop()` 是同一个下标——
   * 否则「选沙海得到橙色按钮」这条承诺就只在设置页成立，按钮仍停在旧色上。
   */
  private scheme(): AccentScheme {
    return Palette.scheme(Palette.indexOf(this.backdrop().accentKey));
  }

  /**
   * 任一主题配套的强调色。设置页五个色点要画**各自**的色相，不能都画当前那个，
   * 否则五个圆点全是一个颜色，等于没有比较。
   */
  private accentOf(theme: ContourTheme): string {
    return Palette.scheme(Palette.indexOf(theme.accentKey)).accent(this.activeDark());
  }

  private accentColor(): string {
    return this.scheme().accent(this.activeDark());
  }

  private onAccentColor(): string {
    return this.scheme().onAccent(this.activeDark());
  }

  private accentChipColor(): string {
    return this.scheme().chipBg(this.activeDark());
  }

  /**
   * Translucent surface veil painted over the immersive material, so a card
   * reads as a card instead of dissolving into the accent backdrop.
   *
   * Tuned by pixel-sampling the device. At 70 % the veil was still letting the
   * material's own darkening through and the measured card came out *darker* than
   * the page (card `#EDF5F6` vs backdrop `#F1F9F9`) — a glass slab sunk into the
   * background rather than a surface sitting on it. 82 % puts the card roughly ten
   * levels above the backdrop, which is what makes the grid read as separate
   * cards, while still passing ~18 % of the material's refraction at the edges.
   *
   * The material itself follows the **system** light/dark setting, not the app's
   * 外观 choice — the API has no "use app theme" switch — so these two are driven
   * by `activeDark()` and a forced-dark app on a light-system device stays black.
   */
  private glassTint(): string {
    return this.activeDark() ? '#CC1C1C1E' : '#D1FDFEFF';
  }

  /**
   * Whether content-area surfaces may paint the immersive material.
   *
   * Requires *both* that the API exists (API 26 gate on `hdsSupported`) and that
   * the device advertises `MaterialType.IMMERSIVE`. Both false → every surface
   * falls back to its opaque fill, never to transparent.
   */
  private glassOn(): boolean {
    return this.hdsSupported && this.immersiveSupported;
  }

  onPageShow(): void {
    if (this.store.ready) {
      this.store.reload();
      this.refreshList();
    }
  }

  // ------------------------------------------------------------ navigation

  @Builder
  pageMap(name: string) {
    if (name === 'reader') {
      ReaderPage({
        pathStack: this.pathStack,
        accentColor: this.accentColor(),
        onChanged: () => {
          this.refreshList();
        }
      })
    } else if (name === 'trash') {
      TrashPage({
        pathStack: this.pathStack,
        accentColor: this.accentColor()
      })
    } else if (name === 'webdav') {
      WebDavPage({
        pathStack: this.pathStack,
        accentColor: this.accentColor(),
        accentChipColor: this.accentChipColor()
      })
    }
  }

  /**
   * 卡片点击 → 笔记页。笔记页本身就是编辑器（点哪块改哪块），
   * 所以这里不再有「先进只读页、再点编辑」的第二道门。
   */
  private openNote(note: Note): void {
    const param: ReaderParam = { id: note.id, created: false };
    this.pathStack.pushPath({
      name: 'reader',
      param: param
    });
  }

  /**
   * 新建笔记并直接进入。
   *
   * 进的是**笔记页**，不是另一个编辑器：`+` 之后应当立刻能写，而不是先把用户
   * 送到一套不同的界面再让他重新学一遍「怎么改」。新建的笔记正文只有骨架标题，
   * 笔记页据此把光标直接放进标题块，键盘随即弹出。
   *
   * `createNote()` 仍然立刻落盘——笔记页要按 id 读取它。误触的代价由笔记页承担：
   * 从 `created: true` 进来、一个字都没写就离开时，它会把空笔记收掉
   * （`ReaderPage.goBack`），所以不会在列表里留下「无标题」。
   */
  private newNote(): void {
    const note: Note = this.store.createNote();
    this.refreshList();
    const param: ReaderParam = { id: note.id, created: true };
    this.pathStack.pushPath({
      name: 'reader',
      param: param
    });
  }

  /**
   * 让筛选带的显隐走向当前页签的目标状态。
   *
   * 只在一个地方改状态，收放都走这里，所以「切到设置页」「切回笔记页」「删掉最后一个
   * 标签导致标签页没有筛选带」三种情况节奏一致。
   *
   * ## 两个方向不对称，因为两个方向的坑不一样
   *
   * 收起：控件淡出（`BAND_FADE_MS`）→ 留白与结构**一起**收（`BAND_CLOSE_MS`）。
   * 展开：留白撑开（`BAND_OPEN_MS`）→ 挂结构 → 控件淡入（`BAND_FADE_MS`）。
   *
   * **收起时结构与留白同时改，展开时必须分开。** 收起方向结构是「摘掉」，页面留白
   * 的插值不受影响（摘掉之后 padding 还在动）；而展开方向结构是「插入」，`animateTo`
   * 一旦碰上结构变化就会把 padding 重算成终值、插值被跳过——实测 `外观` 一帧从
   * 419 px 跳到 313 px 再跳回 435 px。所以展开时先让留白走完，再挂结构。
   *
   * 两个方向共同的前提：**留白只在控件不可见的时候动**。反过来的话，34 vp 的胶囊
   * 会被塞进一条越来越矮的带子里，看着像被压扁。
   */
  private syncBand(): void {
    if (this.bandTimer >= 0) {
      clearTimeout(this.bandTimer);
      this.bandTimer = -1;
    }
    const gone: boolean = this.bandTargetGone();
    if (!gone) {
      // 两个页签**都有**带子时（笔记 ⇄ 标签），内容整条换掉就够了：高度没变，
      // 没有任何位移需要动画，淡出淡入反而会让控件凭空闪一下。
      if (this.bandShown && !this.bandFading) {
        this.bandTab = this.selectedTab;
        return;
      }
      // 展开，顺序与收起严格相反：
      // 1. 留白撑开（结构还不在，控件也还透明——整段只有内容在下移）；
      // 2. 撑满之后才挂上这一带；
      // 3. 最后让控件淡入。
      //
      // 第 2 步必须晚于第 1 步：`bottomBuilder.height` 一挂上就是满高，而页面留白
      // 是另一条插值；先挂结构等于让 HDS 先占住 50 vp，`animateTo` 随即被打断
      // （实测 `外观` 一帧从 419 px 跳到 313 px 再跳回 435 px）。
      this.bandTab = this.selectedTab;
      this.bandFading = true;
      animateTo({ duration: BAND_OPEN_MS, curve: Curve.FastOutSlowIn }, () => {
        this.bandInset = BOTTOM_BUILDER_HEIGHT;
      });
      this.bandTimer = setTimeout(() => {
        this.bandTimer = -1;
        // 此刻留白已经是满的：挂上这一带前后，内容位置完全一致，只有材质出现。
        // 控件仍是全透明，所以这一次插入看不出跳变。
        this.bandShown = true;
        animateTo({ duration: BAND_FADE_MS, curve: Curve.FastOutSlowIn }, () => {
          this.bandFading = false;
        });
      }, BAND_OPEN_MS);
      return;
    }
    // 收起。已经在收 / 已经收完就不再重来一次，否则连点两下会来回抖。
    if (!this.bandShown && this.bandInset === 0) {
      return;
    }
    // 第一段：控件淡出。带子还在，内容仍是**原来那个页签**的（`bandTab` 不动），
    // 所以看到的是「笔记的筛选条淡出」，不是「忽然变成标签页的筛选条再淡出」。
    animateTo({ duration: BAND_FADE_MS, curve: Curve.FastOutSlowIn }, () => {
      this.bandFading = true;
    });
    // 第二段：看不见之后合拢。这里结构**与留白同时**收——收起方向没有「结构插入
    // 重算 padding」的问题（那是展开方向的坑），而分开做反而会多出一段「bar 还有
    // 145 vp、内容只让 95 vp」的窗口：内容会滑到材质底下再让 bar 追上，闪一下。
    this.bandTimer = setTimeout(() => {
      this.bandTimer = -1;
      animateTo({ duration: BAND_CLOSE_MS, curve: Curve.FastOutSlowIn }, () => {
        this.bandInset = 0;
        this.bandShown = false;
      });
    }, BAND_FADE_MS);
  }

  /**
   * 当前页签是否**不该有**筛选带。
   *
   * 设置页没有筛选 / 排序，标签页在没有标签时也没有——那两处整块不给
   * `bottomBuilder`，而不是留一条高度 0 的空带。
   */
  private bandTargetGone(): boolean {
    if (this.selectedTab === 0) {
      return false;
    }
    if (this.selectedTab === 1 && this.tagsSnapshot.length > 0) {
      return false;
    }
    return true;
  }

  /**
   * 页签切换的唯一入口。页签栏的 `onChange` 只做一件事：把它转进来。
   *
   * 标题栏只有一套搜索框，搜索词作用在**当前**页签上。不清掉的话，笔记页搜
   * 「欢迎」再切到标签页，标签页会带着一个它自己从没输入过的过滤条件，看起来
   * 像是标签莫名少了一半。
   *
   * `includeArchived` 一并归零：「全量搜索」是用户在某一次搜索结果上做的决定，
   * 不是常驻偏好，换页签之后再回来不该还带着归档的那些。
   *
   * 不在这里调 `hdsTabs.changeIndex()`：本方法就是被 `onChange` 调的，再调回去
   * 是让平台自己通知自己。`filterByTag()` 那种**程序**切页签才需要显式 changeIndex。
   */
  private switchTab(index: number): void {
    if (index === this.selectedTab) {
      return;
    }
    this.selectedTab = index;
    this.searchExpanded = false;
    this.query = '';
    this.includeArchived = false;
    // 另一个页签是另一条滚动轴：上一个页签里「往上滑到一半」的状态带过来，
    // 会让新页签的顶栏一开始就是收起的，而用户根本没滑过它。
    this.restoreChrome();
    this.syncBand();
  }

  /**
   * Tag → notes drill-down.
   *
   * A tag is just a query, so this deliberately routes through the same search
   * state instead of a private "tag filter" that nothing on the notes page
   * displays. Without that, tapping a tag silently filtered the grid while the
   * page still looked identical to the unfiltered list, and the user had no way
   * to see — let alone clear — the active constraint.
   *
   * The search field is expanded but NOT focused: focusing it would pop the
   * keyboard over the very results the user came to read.
   */
  private filterByTag(tag: string): void {
    this.query = tag;
    this.includeArchived = false;
    this.searchExpanded = true;
    if (this.selectedTab !== 0) {
      this.selectedTab = 0;
      this.hdsTabs.changeIndex(0);
      // 程序切页签也会换掉筛选带的目标高度，所以同样要走这条过渡。
      this.syncBand();
    }
  }

  // --------------------------------------------------------------- title bar

  /**
   * The title row is built entirely in `stackBuilder`.
   *
   * HDS's own `title` + `menu` pairing cannot reproduce the reference layout on
   * this device image: in FULL mode `stackBuilder` is laid out as a band *above*
   * the large title (measured title at y 316…421 with actions at y 141…261), so
   * the title and the two circular buttons end up on different rows, and the
   * built-in `menu` slot squeezes every icon to ~3 px inside a 9 vp button.
   *
   * Supplying the whole row through `stackBuilder` and leaving `title` unset
   * keeps HDS's material, scroll blur and safe-area handling while giving the
   * title, the buttons and the expanding search field one shared Row — which is
   * exactly the reference. It also reclaims the vertical space the separate
   * large-title band was consuming.
   */
  private titleBarOptions(): HdsNavigationTitleBarOptions {
    // 筛选条 / 排序条住在标题栏的**底部区域**里。这不是排版偏好：`systemMaterial`
    // 只在 Navigation/NavDestination 标题栏、以及 `barPosition(End)` 的底部页签栏
    // 里生效，页面内容区一律不生效（官方功耗优化文档：「在其他区域中设置沉浸光感
    // 效果不生效」）。从前它们留在内容区，只能靠 `MaterialLayer` 用不可见 `Toggle`
    // 当载体；搬进这里之后材质由控件自己画，那个载体在本页就不需要了。
    //
    // 这一带给不给，看的是 `bandShown` 而不是当前页签：设置页没有这两条、标签页在
    // 没有标签时也没有，那两处**整块不给** `bottomBuilder`，而不是给一条高度 0 的
    // 空带（后者仍会参与标题栏布局，只是看不见）。但它不是随页签瞬时翻转的——
    // 何时收、何时挂由 `syncBand()` 排队，页面留白另由 `bandInset` 插值。
    const content: TitleBarContentOptions = {
      stackBuilder: () => {
        this.TitleRow();
      }
    };
    const band: number = this.titleBottomHeight();
    if (band > 0) {
      content.bottomBuilder = {
        builder: (): void => {
          this.TitleBottom();
        },
        height: band
      };
    }
    const scroll: ScrollEffectOptions = {
      enableScrollEffect: true,
      scrollEffectType: ScrollEffectType.IMMERSIVE_GRADIENT_BLUR
    };
    const material: SystemMaterialParams = {
      materialType: this.materialType(),
      materialLevel: this.materialLevel()
    };
    // HDS defaults the large title to white, which is invisible on the light
    // background. Pin both the resting and the scrolled style so each theme
    // resolves its own primary text colour.
    const titleStyle: HdsNavigationTitleStyle = {
      mainTitleColor: $r('sys.color.ohos_id_color_text_primary')
    };
    const contentStyle: HdsTitleBarContentStyle = { titleStyle: titleStyle };
    const original: HdsNavigationTitleBarStyle = { contentStyle: contentStyle };
    const scrolled: HdsNavigationTitleBarStyle = { contentStyle: contentStyle };
    const style: TitleBarStyleOptions = {
      scrollEffectOpts: scroll,
      systemMaterialEffect: material,
      originalStyle: original,
      scrollEffectStyle: scrolled
    };
    return { content: content, style: style };
  }

  /**
   * One row: page title, then the search slot and the new-note button. Tapping
   * the search circle grows it into a full-width rounded field *in place*, so
   * there is no second always-visible search box competing with it.
   */
  @Builder
  TitleRow() {
    Row({ space: 8 }) {
      if (this.searchExpanded) {
        this.SearchField()
      } else {
        Text(this.tabTitle())
          .fontSize(28)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('sys.color.ohos_id_color_text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }

      // 搜索与新建是**每个页自己的**动作：笔记页是搜索笔记 / 新建笔记，标签页是
      // 搜索标签 / 新建标签。按钮外形与笔记页完全一致（同一个 CircleAction）。
      //
      // **设置页两个都不给**。这一页没有「新建」可言，而搜索是笔记内容的检索——
      // 十行配置一眼扫完，在设置页放一个搜索框只会暗示「设置可以搜」，点下去又
      // 什么也搜不出来。所以整块动作位不渲染，标题自己把这一行铺满。
      if (!this.searchExpanded && this.selectedTab !== 2) {
        this.CircleAction($r('sys.symbol.magnifyingglass'), () => {
          this.openSearch();
        }, this.selectedTab === 1 ? '搜索标签' : '搜索')
      }

      // 搜索框展开时右侧那颗圆钮换成「收起搜索」。这一格是标题行的主动作位：
      // 展开状态下主动作就是退出搜索，而「新建」此时是一个会把人从搜索里拽走的
      // 动作——点了它不是放弃搜索，是带着半个词去开一篇空白笔记。
      //
      // 用它而不是在输入框里再放一颗 ×：退出搜索只有一个出口。输入框里那颗 ×
      // 只清词、不收起，于是「干净地退出」要先清词再点一次、还要先收键盘；两颗
      // 一样大的 × 并排更是同一次动作读了两遍。
      if (this.searchExpanded) {
        this.CircleAction($r('sys.symbol.xmark'), () => {
          this.closeSearch();
        }, '收起搜索')
      } else if (this.selectedTab === 0) {
        this.CircleAction($r('sys.symbol.plus'), () => {
          this.newNote();
        }, '新建笔记')
      } else if (this.selectedTab === 1) {
        this.CircleAction($r('sys.symbol.plus'), () => {
          this.openTagNameEditor(false, '');
        }, '新建标签')
      }
    }
    .width('100%')
    .height(TITLE_ROW_HEIGHT)
    .padding({ left: this.SIDE_INSET, right: this.SIDE_INSET })
    .alignItems(VerticalAlign.Center)
  }

  /**
   * 标题栏底部那一带：筛选条 / 排序条，或（多选时）动作条。
   *
   * ## 为什么在这里，而不是页面内容区
   *
   * `systemMaterial` 只在 Navigation/NavDestination 标题栏与 `barPosition(End)`
   * 的底部页签栏里生效；页面内容区「设置沉浸光感效果不生效」（官方功耗优化
   * 文档明文）。所以筛选条以前只能靠 `MaterialLayer` 用一个不可见的 `Toggle`
   * 当载体去画材质。搬进标题栏之后，材质由这个容器自己画——这正是官方给的正例
   * （在标题栏里为**局部容器**设置沉浸式系统材质）。
   *
   * 高度由 `titleBarOptions().bottomBuilder.height` 决定，必须与这里一致：
   * `BOTTOM_BUILDER_HEIGHT` 是唯一的数，页面顶部留白也由它推算
   * （`titleBandHeight()`）。
   *
   * 页签变化时这一带会整条换内容而不是叠加：设置页没有筛选，标签页在没有标签时
   * 也没有——两处 `bandTargetGone()` 返回 true，HDS 直接不留这一带。
   */
  @Builder
  TitleBottom() {
    Row({ space: 8 }) {
      if (this.selecting && this.bandTab === 0) {
        // 多选态：整条换成动作条。高度与筛选条完全相同（34 vp），所以进出多选
        // 网格不会上下一跳。
        this.SelectionCapsule()
      } else if (this.bandTab === 0) {
        this.ChipGroup(0)
        this.ChipGroup(10)
      } else {
        // 标签页的顺序与笔记页一致：**先筛选、后排序**。
        this.TagChipGroup(1)
        this.TagChipGroup(0)
      }
    }
    .width('100%')
    .height(BOTTOM_BUILDER_HEIGHT)
    .padding({
      left: this.SIDE_INSET, right: this.SIDE_INSET,
      top: (BOTTOM_BUILDER_HEIGHT - 34) / 2, bottom: (BOTTOM_BUILDER_HEIGHT - 34) / 2
    })
    .alignItems(VerticalAlign.Center)
    // 淡出由 `syncBand()` 里的 `animateTo` 驱动（它改 `bandFading`），这里只读状态、
    // 不挂 `.animation()`：两处各挂一条曲线就是两条各走各的。
    .opacity(this.bandFading ? 0 : 1)
  }

  /** 展开标题栏里的搜索框。搜索词是共享的，作用在当前页签上。 */
  private openSearch(): void {
    // 搜索框在标题栏里，而标题栏可能是收起的（用户滑到一半点了放大镜）。
    // 先把 chrome 复位，输入框才不会一开始就挂在一条让开的空带子上。
    this.restoreChrome();
    this.searchExpanded = true;
    setTimeout(() => {
      this.getUIContext().getFocusController().requestFocus(SEARCH_INPUT_ID);
    }, 80);
  }

  /**
   * 收起搜索框，回到标题 + 放大镜 + 新建。
   *
   * 唯一入口是标题行右侧那颗 ×（展开时它取代新建按钮）。从前这里有两颗按钮：
   * 输入框右端一颗只清词的 ×，右侧一颗新建——于是「干净地退出搜索」要先清词、
   * 再点一次、还得先收键盘，而两颗一样大的 × 并排把同一次动作读了两遍。
   *
   * 查询一并清空：收起的语义是「这一轮搜索结束了」，留下一个看不见的过滤条件
   * 会让网格继续少一半卡片，而屏幕上没有任何东西解释为什么。
   */
  private closeSearch(): void {
    this.query = '';
    this.includeArchived = false;
    this.searchExpanded = false;
    // 键盘得自己收：输入框被移出组件树时软键盘不会立刻跟着走，它会悬在列表上。
    this.getUIContext().getFocusController().clearFocus();
    this.restoreChrome();
  }

  /**
   * Circular action button on the title bar.
   *
   * This sits inside the `Navigation` title bar (`stackBuilder`), which is one of
   * the few places where the platform's immersive material is actually in scope —
   * so it uses the real thing: `.systemMaterial(uiMaterial.ImmersiveMaterial)`.
   * That buys the platform's own material-layer filter, its shadow and, with
   * `interactive: true`, the press deformation plus light response, none of which
   * a hand-built blur can reproduce.
   *
   * Two consequences are load-bearing:
   *  - `backgroundColor` must stay `Color.Transparent`. Per the `uiMaterial`
   *    docs, once `systemMaterial` takes effect on a high/medium-tier device it
   *    "会被恢复为透明色" — and on a *low*-tier device the material falls back to
   *    painting with `materialColor`, so a tint here would be ignored anyway.
   *  - do **not** set `border`. `borderWidth` is reset to no border by the same
   *    rule, and `applyShadow` (default true) overrides the `shadow` attribute.
   *
   * The circle comes from `borderRadius(22)` on a 44×44 node — **not** from
   * `clipShape(CircleShape)`. See the attribute for why that distinction is the
   * whole fix for the ragged rim.
   *
   * Below API 26, or on a device without immersive material, this degrades to the
   * hand-built glass stack — the button never disappears.
   */
  @Builder
  CircleAction(icon: Resource, onTap: () => void, label: string) {
    if (this.immersiveSupported) {
      Stack({ alignContent: Alignment.Center }) {
        SymbolGlyph(icon)
          .fontSize(20)
          .fontColor([$r('sys.color.ohos_id_color_text_primary')])
      }
      .width(44)
      .height(44)
      // The material's **own** shape must be the circle.
      //
      // This used `clipShape(CircleShape)`, which clips the node's *drawing* but
      // does not tell the material layer what shape to paint. The material then
      // paints its default rounded rectangle and the circle cuts its corners
      // away, leaving the rectangle's four straight edges visible as bright arcs
      // at 12/3/6/9 o'clock — the 「边缘光感异常」 report. It is obvious in dark
      // mode, where those arcs are white slivers on a dark disc.
      //
      // `borderRadius(22)` on a 44×44 node *is* a circle, and it is the shape the
      // material rasterises, so the rim follows the disc exactly.
      .borderRadius(22)
      .backgroundColor(Color.Transparent)
      .systemMaterial(this.immersiveMaterial(true))
      .onClick(onTap)
      .accessibilityText(label)
    } else {
      Stack({ alignContent: Alignment.Center }) {
        Column()
          .width('100%')
          .height('100%')
          .linearGradient({
            angle: 180,
            colors: [[$r('app.color.glass_hi'), 0.0], ['#00FFFFFF', this.glassSheenStop()]]
          })
        SymbolGlyph(icon)
          .fontSize(20)
          .fontColor([$r('sys.color.ohos_id_color_text_primary')])
      }
      .width(44)
      .height(44)
      .borderRadius(22)
      .clip(true)
      .backgroundEffect(this.glassEffect())
      .border({ width: this.glassRimWidth(), color: $r('app.color.glass_border') })
      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
      .onClick(onTap)
      .accessibilityText(label)
    }
  }

  /**
   * The platform immersive material, configured from the current gear.
   *
   * `ImmersiveStyle` is the *thickness* axis the docs describe ("不同材质样式对应
   * 不同的材质厚薄程度，主要包括材质的模糊程度、高光效果"). It is deliberately derived
   * from the same `glassLevel` gear as the HDS compute level so the two material
   * families on screen deepen together instead of drifting apart. Note it only
   * has an effect on high/medium-tier devices — the docs state that on low-tier
   * devices "ImmersiveStyle 枚举不生效" and a single style is used.
   *
   * The thickness ordering follows the official guidance: THIN for floating
   * buttons, REGULAR for content, THICK+ when depth is being emphasized.
   *
   * `applyShadow` is explicitly **off** for these two chrome surfaces, and that
   * is the fix for the 「边缘光感异常」 report. The documented default is `true`,
   * and the shadow is drawn from the *unclipped* node: on a 44 vp circle that is
   * clipped with `clipShape(CircleShape)` / `borderRadius(22) + clip(true)`, the
   * shadow survives the clip as a crescent hugging the inside of the rim, which
   * reads as a dirty glowing edge rather than as depth. A floating 44 vp control
   * on a soft backdrop does not need a drop shadow at all; the material's own
   * rim highlight is the edge.
   *
   * `lightEffect` is what makes the press highlight 跟随强调色: the docs describe it
   * as "自定义光感反馈的颜色" and default it to `Color.White`. A white specular on a
   * near-white backdrop is exactly the second half of the "异常" complaint — there
   * was no visible response to a press, just a static pale disc.
   */
  private immersiveMaterial(interactive: boolean): uiMaterial.ImmersiveMaterial {
    const styles: uiMaterial.ImmersiveStyle[] = [
      uiMaterial.ImmersiveStyle.REGULAR,     // 自适应 — 官方默认
      uiMaterial.ImmersiveStyle.ULTRA_THICK, // 高
      uiMaterial.ImmersiveStyle.REGULAR,     // 中
      uiMaterial.ImmersiveStyle.THIN         // 低
    ];
    const light: uiMaterial.LightEffectOptions = { color: this.accentColor() };
    const options: uiMaterial.ImmersiveOptions = {
      style: styles[this.glassIndex()],
      interactive: interactive,
      applyShadow: false,
      lightEffect: light
    };
    return new uiMaterial.ImmersiveMaterial(options);
  }

  /**
   * Backdrop-blur parameters for the hand-built glass surfaces (title buttons,
   * search field, chip capsules).
   *
   * This is deliberately *not* the platform's immersive material. Per the
   * `@ohos.arkui.uiMaterial` docs, immersive material only takes effect inside a
   * `Navigation`/`NavDestination` title bar or a `barPosition(End)` bottom tab
   * bar; "在其他区域中设置沉浸光感效果不生效". The filter/sort capsules live in the
   * page content, so they can never use it — which is why the whole surface family
   * shares this hand-built glass instead.
   *
   * `saturation` > 1 is the important part: plain blur desaturates whatever is
   * behind it and the surface reads as frosted plastic. `brightness` lifts the
   * result so the glass stays legible on the dark backdrop too.
   *
   * The four gears mirror the platform's own four material levels
   * (ADAPTIVE / EXQUISITE / GENTLE / SMOOTH). Thickness is tied to the same gear
   * because a higher compute tier affords a heavier material, and because the
   * official recommendation for `ImmersiveStyle` is the same ordering: THIN for
   * floating buttons, REGULAR for content, THICK when depth is being emphasized.
   */
  private glassEffect(): BackgroundEffectOptions {
    // index 0/1/2/3 = 自适应 / 高 / 中 / 低
    const radius: number[] = [24, 32, 24, 16];
    const saturation: number[] = [1.8, 2.1, 1.8, 1.4];
    const brightness: number[] = [1.04, 1.06, 1.04, 1.02];
    const i = this.glassIndex();
    const effect: BackgroundEffectOptions = {
      radius: radius[i],
      saturation: saturation[i],
      brightness: brightness[i],
      color: $r('app.color.glass_tint')
    };
    return effect;
  }

  /** `glassLevel` clamped into the gear table's range. */
  private glassIndex(): number {
    if (this.glassLevel < GLASS_LEVEL_MIN) {
      return GLASS_LEVEL_MIN;
    }
    if (this.glassLevel > GLASS_LEVEL_MAX) {
      return GLASS_LEVEL_MAX;
    }
    return this.glassLevel;
  }

  /**
   * Strength of the specular sheen. A faint rim at the low gear, a strong
   * top-down gloss at the high gear. Tied to the gear rather than fixed because a
   * deep blur with a barely-there sheen looks like frosted plastic, and a heavy
   * sheen over a shallow blur looks like a sticker.
   */
  private glassSheenStop(): number {
    const stops: number[] = [0.62, 0.74, 0.62, 0.4];
    return stops[this.glassIndex()];
  }

  /** Rim opacity — the edge highlight that separates glass from a flat fill. */
  private glassRimWidth(): number {
    const widths: number[] = [1, 1.5, 1, 0.5];
    return widths[this.glassIndex()];
  }

  /**
   * The device's own material tier, read once from `uiMaterial`. This exists to
   * make the 自适应 gear honest: the platform decides the real level from
   * hardware, and `getGlobalMaterialLevel()` is the only way to see which tier
   * that is. Read-only by design — the docs state the level "不支持设置".
   */
  private deviceTierLabel(): string {
    switch (this.deviceTier) {
      case 0:
        return '高算力';
      case 1:
        return '中算力';
      case 2:
        return '低算力';
      default:
        return '未知';
    }
  }

  private tabTitle(): string {
    if (this.selectedTab === 1) {
      return '标签';
    }
    if (this.selectedTab === 2) {
      return '设置';
    }
    return '笔记';
  }

  // ------------------------------------------------------------- tab bar

  private floatingBarStyle(): HdsTabsFloatingStyle {
    /*
     * Compact capsule widths, deliberately well under the window width.
     *
     * `HdsBarWidthRangeOptions` picks a bucket from the *window* width, and the
     * buckets are `smallWidth` (< 440 vp), `mediumWidth` (440–600 vp) and
     * `largeWidth` (> 840 vp). This device is exactly 440 vp wide, so it lands in
     * the **medium** bucket. The previous `mediumWidth: 400` therefore produced a
     * 400 vp bar on a 440 vp screen — measured 60…1260 px of 1320, i.e. it read
     * as a full-width slab with 20 vp of air on each side rather than as a
     * floating capsule (the 「下方 tab 菜单过于宽」 report).
     *
     * 300 vp gives 100 vp per 页签 for three tabs — enough for a 22 vp glyph plus
     * a 2-character label — and leaves 70 vp of backdrop on each side so the bar
     * reads as floating. All three buckets are reduced together; leaving `large`
     * at 460 would make the tablet layout *wider* than the phone one relative to
     * its window, which is the opposite of what a floating capsule wants.
     */
    const width: HdsBarWidthRangeOptions = {
      smallWidth: 280,
      mediumWidth: 300,
      largeWidth: 340
    };
    // The mask is the gradient fade under the bar. Transparent because the
    // page backdrop is already a gradient + glow; an opaque plate is exactly
    // the "solid slab" defect the previous bar had.
    const mask: HdsTabsBackgroundStyle = {
      maskColor: Color.Transparent,
      maskHeight: 0
    };
    const material: SystemMaterialParams = {
      materialType: this.materialType(),
      materialLevel: this.materialLevel()
    };
    return {
      barWidth: width,
      barBottomMargin: 28,
      gradientMask: mask,
      // A rim of the same specular white the hand-built surfaces use, so the
      // HDS bar and the custom glass buttons read as one material family
      // instead of "system bar + widgets that happen to be translucent".
      lightColor: $r('app.color.glass_hi'),
      systemMaterialEffect: material
    };
  }

  @Builder
  TabItem(title: string, index: number, symbol: Resource) {
    Column({ space: 2 }) {
      SymbolGlyph(symbol)
        .fontSize(22)
        .fontColor([this.selectedTab === index ? this.accentColor() : $r('sys.color.icon_secondary')])
      Text(title)
        .fontSize(10)
        .fontWeight(this.selectedTab === index ? FontWeight.Bold : FontWeight.Normal)
        .fontColor(this.selectedTab === index ? this.accentColor() : $r('sys.color.icon_secondary'))
    }
    .width('100%')
    .height(52)
    .justifyContent(FlexAlign.Center)
  }

  // ------------------------------------------------------------ page shell

  build() {
    // One backdrop for the whole shell, behind `Navigation` rather than inside
    // each `TabContent`. Per-tab backdrops each computed their own gradient and
    // glow positions, so a horizontal tab switch slid two gradients past each
    // other and their edges met mid-screen — visible as a seam. Hoisting it also
    // means the title bar and the floating capsule sit over the same continuous
    // surface, which is what makes the material sampling coherent.
    Stack({ alignContent: Alignment.TopStart }) {
      this.PageBackdrop()
      Navigation(this.pathStack) {
        if (this.hdsSupported) {
          this.HdsShell()
        } else {
          this.PlainShell()
        }
      }
      .navDestination(this.pageMap)
      .mode(NavigationMode.Stack)
      .hideTitleBar(true)
      .height('100%')
      .width('100%')
      // AI 洞见的进度挂在整个 shell 之上，不在某个页签里：它是手势的反馈，
      // 而手势可能发生在任何一个页签上，且切换页签不该打断它（也不会——请求
      // 由服务层持有，这一层只负责显示）。
      if (this.insightBusy) {
        this.InsightOverlay()
      }
    }
    .width('100%')
    .height('100%')
  }

  /**
   * API 23+ shell: HdsNavigation wraps HdsTabs. The title bar owns the scroll
   * linkage (`bindToScrollable`) so the gradient blur appears only while
   * content is actually underneath, and `barOverlap` + the floating style make
   * the bar a capsule that content scrolls behind.
   */
  @Builder
  HdsShell() {
    HdsNavigation() {
      HdsTabs({ controller: this.hdsTabs, index: this.selectedTab }) {
        TabContent() {
          this.NotesPage()
        }
        .tabBar(this.TabItem('笔记', 0, $r('sys.symbol.doc_text_fill')))

        TabContent() {
          this.TagsPage()
        }
        .tabBar(this.TabItem('标签', 1, $r('sys.symbol.label')))

        TabContent() {
          this.SettingsPage()
        }
        .tabBar(this.TabItem('设置', 2, $r('sys.symbol.gearshape_fill')))
      }
      .vertical(false)
      .barPosition(BarPosition.End)
      .barOverlap(true)
      // 关掉页签横滑。卡片自己有左右滑动手势，两者方向相同、区域重叠；
      // 留着横滑，用户在卡片上滑动就有一半概率切了页签。代价是切换页签只能
      // 点底栏——但底栏本来就一直在。
      .scrollable(false)
      .barFloatingStyle(this.floatingBarStyle())
      .onChange((index: number) => {
        this.switchTab(index);
      })
    }
    // MINI keeps the whole title bar to a single compact row, which is what the
    // reference shows. FULL reserved a separate large-title band *below* the
    // `stackBuilder` row (title bar measured 453 px tall for a 285 px row), so
    // the title and the action buttons landed on different lines.
    .titleMode(HdsNavigationTitleMode.MINI)
    // In MINI mode HDS injects its own back button at the leading edge, which
    // landed on top of the title (measured at x 48…168, the title starts at 48).
    // The root of the stack has nothing to go back to.
    .hideBackButton(true)
    .titleBar(this.titleBarOptions())
    // 顶栏让位：只在整个标题栏都没有正在用的控件时收起。搜索框展开时标题栏就是
    // 输入框本身，把它藏起来等于把用户手上的东西抽走——所以那种情况下不 hide，
    // 否则「滚动时收起顶栏」会变成「搜索时丢失输入框」。
    .hideTitleBar(this.chromeHidden && !this.searchExpanded, true)
    // 三条滚动轴都要绑：标题栏的渐变模糊由「内容是否到了它底下」决定，而每个
    // 页签都有自己的 Scroller。只绑笔记页时，切到设置页上滑，标题栏已经收起、
    // 内容也确实滚到了它底下，但那层模糊永远不出现（它对这一页是「不知道有内容」）。
    .bindToScrollable([this.notesScroller, this.tagsScroller, this.settingsScroller])
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    .width('100%')
    .height('100%')
  }

  /**
   * Pre-API-23 fallback: plain `Tabs` pinned to the bottom with no material.
   * The app still works; it simply loses the floating capsule and the
   * light-sensing title bar.
   */
  @Builder
  PlainShell() {
    Tabs({ barPosition: BarPosition.End, index: this.selectedTab }) {
      TabContent() {
        this.NotesPage()
      }
      .tabBar(this.TabItem('笔记', 0, $r('sys.symbol.doc_text_fill')))

      TabContent() {
        this.TagsPage()
      }
      .tabBar(this.TabItem('标签', 1, $r('sys.symbol.label')))

      TabContent() {
        this.SettingsPage()
      }
      .tabBar(this.TabItem('设置', 2, $r('sys.symbol.gearshape_fill')))
    }
    .barHeight(56)
    // 与 HDS 外壳一致：卡片左右滑动与页签横滑方向冲突，关掉横滑。
    .scrollable(false)
    .onChange((index: number) => {
      this.switchTab(index);
    })
    .width('100%')
    .height('100%')
  }

  // ------------------------------------------------------------- backdrop

  /**
   * 唯一的页面背景：底色渐变 + 一层真实地形等高线。
   *
   * 底色与线条都由「背景主题」决定（`common/ContourTheme.ets`），强调色由同一个
   * 主题**派生**（`ContourTheme.accentKey` → `Palette.indexOf`）。所以界面上
   * 只有一档色相选择：选一个地点，背景与按钮同时换到那一套色相里。
   *
   * 原来那四个 `radialGradient` 光斑随这次改造整个删掉：它们的颜色是强调色的
   * 光斑色（`glow*`），留在等高线上面会盖住线条，而调淡到不盖住就只是一层雾，
   * 不如没有。`Palette` 里那三组没有读者的字段（`glow*` / `page*` / `glass*`）
   * 也一并删除了，免得下一次加主题时被迫凭空发明十二个没人看的 hex。
   *
   * 底色保留三段渐变（160°）而不是纯色：等高线在没有氛围的平底上会「飘」，
   * 而渐变给出上下明暗，山势才像是落在一个空间里。角度与三元 stop 的 0.55
   * 都是从原来的背景继承的，没有为了等高线重新调过——那两个数决定的是页面的
   * 明暗分布，与上面画什么无关。
   *
   * `expandSafeArea` 挂在**画底色这一层**上，不是外层 `Stack`：只有真正绘制
   * 背景的节点扩张才会把状态栏与手势条也染上，扩张容器不会（渐变子节点仍按
   * 未扩张的尺寸排）。这条在 AGENTS 里踩过，深色模式下最明显。
   */
  @Builder
  PageBackdrop() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 160,
          colors: [
            [this.backdrop().top(this.activeDark()), 0.0],
            [this.backdrop().mid(this.activeDark()), 0.55],
            [this.backdrop().bottom(this.activeDark()), 1.0]
          ]
        })
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      // 等高线层。`themeKey` 而不是主题对象：几何文件名就是 key，两者必须对得
      // 上，传对象会让组件多一个「对象身份是否变了」的判断，而它真正需要的只是
      // 一个字符串。
      ContourCanvas({
        themeKey: this.backdrop().key,
        isDark: this.activeDark()
      })
        .width('100%')
        .height('100%')
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None)
  }

  // ---------------------------------------------------------------- notes

  /**
   * Clearance for the title bar band: `状态栏 + 标题行 + 筛选带`.
   *
   * HDS draws `NavBarContent` at the same origin as the title bar, so each tab
   * root must reserve that band itself.
   *
   * **The status-bar term is required, and this was measured the hard way.**
   * Under `ignoreLayoutSafeArea` a `padding` resolves from **window y = 0**, not
   * from the content top — even though the content root itself starts at the
   * status-bar bottom (`ui_dump`: `root` at `[0,117]`). Measured numbers with the
   * bar shown on 笔记页: `HdsTitleBar` is `[0,117][1320,435]` px, i.e. it ends at
   * **145 vp absolute** (`39 status bar + 56 row + 50 band`), and the grid must
   * start at `(145 + 8) * 3 = 459` px. Dropping the term reserved 106 vp and the
   * grid started at 342 px — 39 vp under the capsule, first card row tucked
   * behind it. Keeping the term produced 459 px exactly.
   *
   * Note the asymmetry with `chromeTopInset()`, which has the same origin but a
   * different job (where content goes *after* the bar leaves).
   */
  private titleBandHeight(): number {
    return WindowService.statusBarHeightVp() + TITLE_ROW_HEIGHT + this.bandInset;
  }

  /**
   * Height of the title bar's bottom band **as a structure**: either the full
   * 34 vp capsule + 8 vp air above and below, or nothing at all.
   *
   * 设置页 has no filter / sort row, and 标签页 has nothing to filter before the
   * first tag exists — the band is removed entirely there rather than leaving an
   * empty strip under the title.
   *
   * This is fed to `bottomBuilder.height`, which is a **builder argument**, not a
   * node attribute: `animateTo` cannot interpolate it. So it never takes a
   * fractional value — the animated part lives in `titleBandHeight()`'s
   * `bandInset` term, and this flips only at a moment when the band is invisible
   * either way (contents faded out, inset already 0).
   */
  private titleBottomHeight(): number {
    return this.bandShown ? BOTTOM_BUILDER_HEIGHT : 0;
  }

  /**
   * 页面内容的顶部留白。
   *
   * 顶栏收起时整条 bar（标题行 + 筛选条那一带）一起让开，所以留的是状态栏下沿
   * + 8 vp：内容原点是窗口顶端，8 vp 会压在时钟上。
   *
   * 没有 HDS 外壳（API < 23，`PlainShell`）时根本没有标题栏，筛选条回到内容区，
   * 这里只留一点呼吸。
   */
  private pageTopInset(): number {
    if (!this.hdsSupported) {
      return 12;
    }
    return this.chromeHidden ? this.chromeTopInset() : this.titleBandHeight() + 8;
  }

  /**
   * Width of one grid column in vp. `WaterFlow` measures a `FlowItem`'s child
   * against the whole flow, so a card must be given an explicit column width or
   * wide content bleeds across into the next column.
   */
  private columnWidth(): number {
    const widthPx = display.getDefaultDisplaySync().width;
    const density = display.getDefaultDisplaySync().densityPixels;
    const widthVp = widthPx / density;
    // 泳道宽 = (可用宽 - 左右内边距 - 缝) / 2
    return (widthVp - this.SIDE_INSET * 2 - this.columnsGapVp()) / 2;
  }

  /**
   * 双列网格的列间距（vp）。
   *
   * 单独提出来是因为它有**两个读者**：`columnWidth()` 要减掉它、`.columnsGap()` 要用
   * 它。两处各写一个 12 就会静默漂移——某天调了间距，卡片宽了、网格挤了，却很难定
   * 位到是哪里没跟上。
   */
  private columnsGapVp(): number {
    return 12;
  }

  @Builder
  NotesPage() {
    Column() {
      // 最近搜索贴在搜索框下面（搜索框在标题栏里）。它只在「搜索框展开且查询为
      // 空」时出现，所以标题栏那一段的留白由它来顶——`NotesHeader` 在它出现时
      // 只留 8 vp，两行不会叠出一条空白带。
      if (this.historyVisible()) {
        this.SearchHistory()
      }

      this.NotesHeader()

      // 归档提示贴着筛选条放，**不进滚动区、也不放页底**：页底在键盘弹起时会
      // 被顶出去，而这条提示恰恰是搜索时（键盘在位）才需要看见的。
      // `WaterFlow` 的 `FlowItem` 不能跨列，所以它也不能塞进网格里。
      if (this.hasArchivedHits()) {
        this.ArchivedSearchHint()
      }

      if (this.visibleNotes().length === 0) {
        this.EmptyState()
      } else {
        WaterFlow({ scroller: this.notesScroller }) {
          ForEach(this.visibleNotes(), (note: Note) => {
            FlowItem() {
              // A `FlowItem` measures its child against the flow container, not
              // against the column slot, so a card whose content is wider than
              // one column (long title + wrapping tag Flex) expanded to the full
              // grid width and overlapped its neighbour. Pinning the cell to the
              // computed column width removes that ambiguity.
              Column() {
                  NoteCard({
                    noteId: note.id,
                    title: note.title,
                    excerpt: note.excerpt,
                    tags: note.tags,
                    archived: note.archived,
                    favorite: note.favorite,
                    updatedAt: note.updatedAt,
                    accentColor: this.accentColor(),
                    accentChipColor: this.accentChipColor(),
                    onAccentColor: this.onAccentColor(),
                    cornerRadius: this.cardCorner,
                    glassOn: this.glassOn(),
                    glassGear: this.glassLevel,
                    glassTint: this.glassTint(),
                    darkTheme: this.activeDark(),
                    selecting: this.selecting,
                    selected: this.selectedIds.includes(note.id),
                    onOpen: (id: string) => {
                      const target = this.store.find(id);
                      if (target !== undefined) {
                        this.openNote(target);
                      }
                    },
                    onToggleSelect: (id: string) => {
                      // 已在多选里就是勾/取消勾；不在就是「进入多选并选上这一张」
                      // ——长按菜单里的「多选」走的是同一条路径。
                      if (this.selecting) {
                        this.toggleSelect(id);
                      } else {
                        this.enterSelect(id);
                      }
                    },
                    onExport: (id: string) => {
                      const target = this.store.find(id);
                      if (target !== undefined) {
                        this.exportNote(target);
                      }
                    },
                    onDuplicate: (id: string) => {
                      const target = this.store.find(id);
                      if (target !== undefined) {
                        this.duplicateNote(target);
                      }
                    },
                    onArchive: (id: string) => {
                      const target = this.store.find(id);
                      if (target !== undefined) {
                        this.store.toggleArchive(target);
                        this.refreshList();
                        Toast.show(this.getUIContext(), target.archived ? '已归档' : '已取消归档');
                      }
                    },
                    onToggleFavorite: (id: string) => {
                      const target = this.store.find(id);
                      if (target !== undefined) {
                        this.store.toggleFavorite(target);
                        this.refreshList();
                      }
                    },
                    onDelete: (id: string) => {
                      const target = this.store.find(id);
                      if (target !== undefined) {
                        this.store.deleteNote(target);
                        this.refreshList();
                      }
                    },
                    onEditTags: (id: string) => {
                      const target = this.store.find(id);
                      if (target !== undefined) {
                        this.openTagEditor(target);
                      }
                    },
                    onInsight: (id: string) => {
                      this.runInsight(id);
                    }
                  })
              }
              // 裁在单元格边界。`FlowItem` 本来就会裁（实测删掉 `.clip(true)` 毫无
              // 变化），写出来是让后来的人看见这条约束——**切口是既成事实**。
              //
              // 所以别在这条线上做文章：加圆角、把裁剪框推到邻列边缘、`zIndex` 沉底、
              // 整卡降不透明度，四条都实测过，换汤不换药。真正消掉它的是把切口处的
              // **色差**压没——`NoteCard.EdgeFade()` 用 `blendMode(DST_IN)` 在格边
              // 最后 44 vp 内做空间渐隐，切口线上没有像素可被切。
              .width(this.columnWidth())
              .clip(true)
            }
          }, (note: Note) => `${note.id}-${note.updatedAt}`)
        }
        .columnsTemplate('1fr 1fr')
        .columnsGap(this.columnsGapVp())
        .rowsGap(12)
        .padding({ left: this.SIDE_INSET, right: this.SIDE_INSET })
        .width('100%')
        .layoutWeight(1)
        // Clears the floating capsule so the last row stays reachable.
        .contentEndOffset(130)
        // 顶栏收起后网格的上边界就在状态栏下沿，卡片滚到那里会被裁成一条直线
        // （实测格边一次跳 20 个色阶）。`fadingEdge` 是平台为这件事给的能力：它在
        // 容器边缘把内容按 alpha 渐隐到背景，所以「被切」变成「淡出」，视觉上与卡片
        // 横滑时格边的 `EdgeFade()` 是同一套语言。
        //
        // 长度取 `CHROME_FADE`（40 vp）而不是默认的 32：这一条要让一整排卡片的高光
        // 边缘都消掉，太短就仍然读得出边界。
        .fadingEdge(true, { fadingEdgeLength: LengthMetrics.vp(CHROME_FADE) })
        // 顶栏 / 页签栏让位的方向判定。`WaterFlow` 有 `onDidScroll`（经
        // `ScrollableCommonMethod`），但回调里的 `scrollOffset` 正负号在容器之间
        // 含义不一致，所以只把它当「发生了一次滚动」的节拍器，位置从
        // `currentOffset()` 读。
        .onDidScroll(() => {
          this.handleChromeScroll(this.notesScroller);
        })
      }
    }
    .width('100%')
    .height('100%')
    .bindSheet(this.tagSheetShown, this.TagSheet(), {
      height: SheetSize.MEDIUM,
      dragBar: true,
      showClose: false,
      backgroundColor: $r('app.color.page_bg'),
      onDisappear: () => {
        this.tagSheetShown = false;
      }
    })
  }

  // ---------------------------------------------------------------- tags

  /**
   * Opens the 标签 sheet for one note.
   *
   * Tags used to be reachable only by hand-editing the `tags:` line in the
   * frontmatter — which meant the 标签 page was a read-only view of a field no
   * UI could write. This is the write path.
   *
   * The working copy starts as a *clone* of the note's tags so cancelling the
   * sheet leaves the note untouched; `commitTags()` is the only writer.
   */
  private openTagEditor(note: Note): void {
    this.tagEditNoteId = note.id;
    this.tagEditTags = note.tags.slice();
    this.tagDraft = '';
    this.tagSheetShown = true;
  }

  private addTag(tag: string): void {
    const cleaned = tag.trim().replace(/^#+/, '').replace(/\s+/g, ' ').trim();
    if (cleaned.length === 0) {
      return;
    }
    if (!this.tagEditTags.includes(cleaned)) {
      // Reassign, never `push`: a `@Local` array is only observed on assignment.
      this.tagEditTags = this.tagEditTags.concat([cleaned]);
    }
    this.tagDraft = '';
  }

  private removeTag(tag: string): void {
    this.tagEditTags = this.tagEditTags.filter((item: string) => item !== tag);
  }

  private commitTags(): void {
    const target = this.store.find(this.tagEditNoteId);
    if (target !== undefined) {
      this.store.setTags(target, this.tagEditTags);
      this.refreshList();
    }
    this.tagSheetShown = false;
  }

  // ------------------------------------------------------------- AI insight

  /**
   * 左重划的落点：让 AI 给这一篇打标签。
   *
   * ## 为什么是「合并」而不是「覆盖」
   *
   * 标签是**用户自己的分类体系**，AI 给的是建议。手打过的 `工作` 不会因为模型这次
   * 想到「效率」就消失——覆盖会让每一次误划都变成一次静默的数据丢失，而这个手势
   * 恰恰是最容易误触的一个（重划到底才触发）。
   *
   * ## 为什么「新建标签」不需要额外动作
   *
   * 见 `AiTags`：标签的存在就等于「有笔记带着它」，写进 frontmatter 就出现在标签
   * 页。所以这里只调 `setTags()`，不调 `TagStore.addTag()`。
   *
   * ## 为什么要一条进度胶囊
   *
   * 这一次不是点按钮触发的，是**手势**触发的：松手之后卡片已经回弹、手指也离开
   * 了屏幕，界面上没有任何东西还停在那儿表示「在做」。请求要等十几秒，不给进度
   * 就只是「划了一下，什么都没发生」。
   */
  private runInsight(id: string): void {
    const target = this.store.find(id);
    if (target === undefined) {
      return;
    }
    if (this.insightBusy) {
      Toast.show(this.getUIContext(), '上一篇还在打标签');
      return;
    }
    if (target.body.trim().length === 0) {
      Toast.show(this.getUIContext(), '这一篇还没有内容');
      return;
    }
    this.insightBusy = true;
    this.insightTarget = target.title.length > 0 ? target.title : '无标题';
    // 快照在**发请求之前**取：等结果回来的十几秒里用户可能已经在别处改过标签，
    // 那时再读 `target.tags` 会读到更新的值，合并的基准就不对了。
    const baseline: string[] = target.tags.slice();
    AiTags.suggest(target.title, target.body, this.tagsSnapshot).then((result: TagSuggestion) => {
      this.insightBusy = false;
      if (!result.ok) {
        Toast.show(this.getUIContext(), result.message);
        return;
      }
      const merged: string[] = baseline.slice();
      const added: string[] = [];
      for (const tag of result.tags) {
        if (!merged.includes(tag)) {
          merged.push(tag);
          added.push(tag);
        }
      }
      if (added.length === 0) {
        Toast.show(this.getUIContext(), '这篇已经有这些标签了');
        return;
      }
      const fresh = this.store.find(id);
      if (fresh === undefined) {
        // 这十几秒里笔记被删了。什么都没写，也就不用提示「已加标签」。
        return;
      }
      // 以当前值为底再合并一次：期间用户手动加的标签不能被这次结果盖掉。
      const finalTags: string[] = fresh.tags.slice();
      const reallyAdded: string[] = [];
      for (const tag of merged) {
        if (!finalTags.includes(tag)) {
          finalTags.push(tag);
          reallyAdded.push(tag);
        }
      }
      if (reallyAdded.length === 0) {
        Toast.show(this.getUIContext(), '这篇已经有这些标签了');
        return;
      }
      this.store.setTags(fresh, finalTags);
      this.refreshList();
      Toast.show(this.getUIContext(), `已加标签 ${reallyAdded.map((tag: string) => `# ${tag}`).join(' ')}`);
    });
  }

  /**
   * 「正在打标签」胶囊。
   *
   * 浮在页底、页签栏之上，`HitTestMode.None` 让整层透明区域不挡手势——它只是一条
   * 状态，不该顺手吃掉用户的下一次点击。宽度撑满只为了居中，胶囊本身是内容宽的。
   */
  @Builder
  InsightOverlay() {
    Column() {
      Row({ space: 8 }) {
        LoadingProgress()
          .width(15)
          .height(15)
          .color($r('sys.color.ohos_id_color_text_secondary'))
        Text(`正在给「${this.insightTarget}」打标签…`)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: 220 })
      }
      .padding({ left: 14, right: 14, top: 8, bottom: 8 })
      .background(this.SettingsCardSurface(), CARD_BG_OPTIONS)
      .borderRadius(17)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.End)
    // 页签栏是 HDS 的浮动胶囊（`barBottomMargin: 28`），再加上它自己的高度，
    // 120 vp 是让这条状态落在栏上方一点、又不会贴到正文最后一行。
    .padding({ bottom: 120 })
    .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  TagSheet() {
    Column({ space: 14 }) {
      Row() {
        Text('标签')
          .fontSize(20)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        Blank()
        Text('完成')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.accentColor())
          .padding({ left: 12, right: 4, top: 6, bottom: 6 })
          .onClick(() => {
            this.commitTags();
          })
          .accessibilityText('保存标签')
      }
      .width('100%')

      Text('标签写在笔记的 frontmatter 里，会随 WebDAV 同步到其他设备。')
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')

      // Current tags. A `Flex` rather than a `Row` so a long list wraps instead
      // of overflowing the sheet.
      if (this.tagEditTags.length === 0) {
        Text('还没有标签')
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
      } else {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.tagEditTags, (tag: string) => {
            Row({ space: 4 }) {
              Text(`# ${tag}`)
                .fontSize(13)
                .fontColor(this.onAccentColor())
              SymbolGlyph($r('sys.symbol.xmark'))
                .fontSize(11)
                .fontColor([this.onAccentColor()])
            }
            .padding({ left: 10, right: 8, top: 5, bottom: 5 })
            .borderRadius(14)
            .backgroundColor(this.accentColor())
            .margin({ right: 8, bottom: 8 })
            .onClick(() => {
              this.removeTag(tag);
            })
            .accessibilityText(`移除标签 ${tag}`)
          }, (tag: string) => `edit-${tag}`)
        }
        .width('100%')
      }

      Row({ space: 8 }) {
        TextInput({ text: this.tagDraft, placeholder: '新标签，回车添加' })
          .layoutWeight(1)
          .height(40)
          .backgroundColor($r('app.color.card_bg'))
          .borderRadius(12)
          .padding({ left: 12, right: 12 })
          .fontSize(14)
          .fontColor($r('app.color.text_primary'))
          .placeholderColor($r('app.color.text_secondary'))
          .caretColor(this.accentColor())
          .onChange((value: string) => {
            this.tagDraft = value;
          })
          .onSubmit(() => {
            this.addTag(this.tagDraft);
          })
        Button('添加')
          .height(40)
          .fontSize(FONT_BODY)
          .backgroundColor(this.accentColor())
          .fontColor(this.onAccentColor())
          .borderRadius(RADIUS_CONTROL)
          .onClick(() => {
            this.addTag(this.tagDraft);
          })
      }
      .width('100%')

      // Existing tags from the whole vault, so tagging reuses a name instead of
      // inventing `work` next to `工作`.
      if (this.store.tags.length > 0) {
        Text('已有标签')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.store.tags, (tag: string) => {
            Text(`# ${tag}`)
              .fontSize(12)
              .fontColor(this.tagEditTags.includes(tag) ? $r('app.color.text_secondary') : this.accentColor())
              .padding({ left: 10, right: 10, top: 5, bottom: 5 })
              .borderRadius(13)
              .backgroundColor(this.tagEditTags.includes(tag) ? $r('app.color.page_bg') : this.accentChipColor())
              .margin({ right: 8, bottom: 8 })
              .opacity(this.tagEditTags.includes(tag) ? 0.5 : 1)
              .onClick(() => {
                this.addTag(tag);
              })
          }, (tag: string) => `vault-${tag}`)
        }
        .width('100%')
      }

      Blank()
    }
    .width('100%')
    .height('100%')
    .padding({ left: this.SIDE_INSET, right: this.SIDE_INSET, top: 12 })
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 页面顶部的呼吸：筛选条 / 排序条已经搬进标题栏（`TitleBottom`），这一页的
   * 第一块内容只需让过**整条标题栏**（标题行 + 筛选条那一带）。
   *
   * `SearchHistory` 自己已经从 `titleBandHeight()` 之下开始排（搜索框展开时顶栏
   * 一定在位），所以它出现时这里只留 8 vp，否则两道留白会叠成一条空带。
   *
   * 顶栏收起时整条 bar 一起让开，留的是**状态栏下沿** + 8 vp：内容原点是窗口顶端，
   * 8 vp 会压在时钟上。
   *
   * **必须给一个显式高度**。这里曾经是一个只有 `padding` 的空 `Column`：空容器
   * 不进布局，那圈 padding 也就跟着消失，网格直接从窗口顶端开始排、第一排卡片
   * 钻到标题栏底下（实测卡片标题与「笔记」二字重叠）。撑开它的是 `height`，不是
   * padding。
   *
   * **API < 23 没有 HDS 标题栏**，筛选条 / 排序条无处可搬，所以那一支仍然自己画
   * 在内容区（`CapsuleSurface` 会退回手搓玻璃）。不保留这一支，老设备上就没有
   * 筛选和排序了——降级是「材质差一点」，不是「功能没了」。
   */
  @Builder
  NotesHeader() {
    Column() {
      if (!this.hdsSupported) {
        // 没有 HDS 标题栏：多选动作条与筛选条仍然要有一条，方向同页头。
        if (this.selecting) {
          this.SelectionCapsule()
        } else {
          Row({ space: 8 }) {
            this.ChipGroup(0)
            this.ChipGroup(10)
          }
          .width('100%')
        }
      }
    }
    .width('100%')
    .height(this.hdsSupported ? (this.historyVisible() ? 8 : this.pageTopInset()) : 42)
    // `height` 是 border-box，所以非 HDS 那一支的 8 vp 呼吸要留在这里；HDS 那一支
    // 的高度本身就是「让过标题栏」的空带，再加 padding 就把它吃掉 8 vp。
    .padding({ left: this.SIDE_INSET, right: this.SIDE_INSET,
      bottom: this.hdsSupported ? 0 : 8 })
    // 不给 `.animation()`：这条高度过渡由 `setChromeHidden()` 里的 `animateTo`
    // 统一驱动，两套动画叠在一起就是「两条曲线各走各的」。
  }

  /**
   * 多选态的动作条：已选数量 + 归档 / 删除 / 导出 + 取消。
   *
   * 它占的正是筛选条那一带（标题栏底部，见 `TitleBottom`），高度完全一致
   * （34 vp），所以进出多选网格不会上下一跳。放在页头而不是页底：底部是 HDS 的
   * 浮动页签栏（`barOverlap`），一条动作条压在它上面会互相遮挡。
   *
   * 三个动作的确认策略不同：归档可逆（笔记只是从「全部」移到「已归档」），不问；
   * 删除不可逆到需要一次确认（30 天回收站），批量删除更是一次处理很多篇，必须
   * 报出数量；导出是只读操作，不问，直接弹保存选择器。
   */
  @Builder
  SelectionCapsule() {
    Stack({ alignContent: Alignment.Center }) {
      this.CapsuleSurface(17)
      Row({ space: 2 }) {
        Text(`已选 ${this.selectedIds.length} 项`)
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.accentColor())
          .padding({ left: 12, right: 8 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        this.SelectionAction('归档', false, () => {
          this.archiveSelected();
        })
        this.SelectionAction('删除', true, () => {
          this.confirmDeleteSelected();
        })
        this.SelectionAction('导出', false, () => {
          this.exportSelected();
        })
        this.SelectionAction('取消', false, () => {
          this.exitSelect();
        })
      }
      .width('100%')
      .height('100%')
      .padding(3)
    }
    .layoutWeight(1)
    .height(34)
    .borderRadius(17)
  }

  @Builder
  SelectionAction(label: string, destructive: boolean, onTap: () => void) {
    Text(label)
      .fontSize(12)
      .fontColor(destructive ? $r('app.color.danger') : this.accentColor())
      .textAlign(TextAlign.Center)
      .layoutWeight(1)
      .height(28)
      .borderRadius(14)
      .maxLines(1)
      .onClick(onTap)
      .accessibilityText(label)
  }

  /**
   * 胶囊外壳：控件自己的沉浸光感（或手搓玻璃 + 一道顶光）。
   *
   * 抽出这一层是因为筛选条 / 排序条 / 多选动作条是**同一个控件家族**。三处各写
   * 一遍材质与顶光，改一处就会漏两处，页面立刻看起来像三个人做的。
   *
   * ## 为什么这里可以用 `.systemMaterial()`，而从前不行
   *
   * 这三条胶囊现在住在标题栏底部（`TitleBottom`），而那正是 `systemMaterial`
   * 生效的两个范围之一（另一个是 `barPosition(End)` 的底部页签栏）。官方功耗
   * 优化文档给的正例就是这个形状：在标题栏里给一个**局部容器**设沉浸式系统
   * 材质。从前它们在页面内容区，那里「设置沉浸光感效果不生效」，只能退回
   * `MaterialLayer` 用一个不可见 `Toggle` 当载体。
   *
   * 三条形状约束，都是踩过的：
   *  - **形状只由 `borderRadius` 给**，不用 `clipShape`，也不给父节点 `clip(true)`。
   *    材质的边缘光按节点自己的圆角栅格化；用 clip 去切会把矩形四条直边留成
   *    12/3/6/9 点钟方向的亮弧（「边缘光感异常」）。
   *  - **`backgroundColor` 保持透明**：材质在上/中算力档会接管背景色，在低算力
   *    档才退回 `materialColor`，这里填色只会让它自己那一档看起来更脏。
   *  - **不设 `border` / `shadow`**：`applyShadow` 默认 true 会覆盖 `shadow`，
   *    而 `borderWidth` 同样会被材质重置。
   *
   * 不支持沉浸光感时退回手搓玻璃：`backgroundEffect` + 顶部一道 `glass_hi` 高光。
   * 两条都是「节点自己的背景」，所以圆角由 `borderRadius` 一并裁好。
   */
  @Builder
  CapsuleSurface(radius: number) {
    if (this.immersiveSupported) {
      Column()
        .width('100%')
        .height('100%')
        .borderRadius(radius)
        .backgroundColor(Color.Transparent)
        .systemMaterial(this.immersiveMaterial(false))
    } else {
      Column()
        .width('100%')
        .height('100%')
        .borderRadius(radius)
        .backgroundEffect(this.glassEffect())
      Column()
        .width('100%')
        .height('100%')
        .borderRadius(radius)
        .linearGradient({
          angle: 180,
          colors: [[$r('app.color.glass_hi'), 0.0], ['#00FFFFFF', this.glassSheenStop()]]
        })
    }
  }

  // ------------------------------------------------------------ selection

  /** 进入多选，并把长按的那张卡**直接算作已选**——菜单里点「多选」的人已经选好了。 */
  private enterSelect(noteId: string): void {
    this.selecting = true;
    this.selectedIds = [noteId];
  }

  private toggleSelect(noteId: string): void {
    if (this.selectedIds.includes(noteId)) {
      this.selectedIds = this.selectedIds.filter((id: string) => id !== noteId);
    } else {
      // 整体赋值，不 `push`：`@Local` 数组只在赋值时被观察到。
      this.selectedIds = this.selectedIds.concat([noteId]);
    }
  }

  private exitSelect(): void {
    this.selecting = false;
    this.selectedIds = [];
  }

  private selectedNotes(): Note[] {
    const result: Note[] = [];
    for (const id of this.selectedIds) {
      const note = this.store.find(id);
      if (note !== undefined) {
        result.push(note);
      }
    }
    return result;
  }

  /**
   * 批量归档。可逆，所以不确认；动作完成后退出多选——用户选这一批就是为了做这
   * 一件事，留着选中态会让格子里的卡全都不见了却还显示「已选 3 项」。
   */
  private archiveSelected(): void {
    const targets = this.selectedNotes();
    if (targets.length === 0) {
      this.exitSelect();
      return;
    }
    let changed: number = 0;
    for (const note of targets) {
      if (!note.archived) {
        this.store.toggleArchive(note);
        changed++;
      }
    }
    this.refreshList();
    this.exitSelect();
    Toast.show(this.getUIContext(), changed > 0 ? `已归档 ${changed} 篇` : '这批笔记已在归档里');
  }

  private confirmDeleteSelected(): void {
    const count = this.selectedIds.length;
    if (count === 0) {
      return;
    }
    // 「已归档」的笔记删起来也没有额外代价，所以一句话说清后果就够了：进回收站、
    // 30 天内可恢复。
    Dialogs.danger(this.getUIContext(), `删除 ${count} 篇笔记`,
      `这 ${count} 篇笔记会移入回收站，保留 30 天。`, '删除', () => {
        const targets = this.selectedNotes();
        let removed: number = 0;
        for (const note of targets) {
          if (this.store.deleteNote(note)) {
            removed++;
          }
        }
        this.refreshList();
        this.exitSelect();
        Toast.show(this.getUIContext(), `已移入回收站 ${removed} 篇`);
      });
  }

  /**
   * 导出选中的笔记。
   *
   * 正文用 `FrontmatterCodec.build(note)` 而不是 `note.body`：导出的 `.md` 要能
   * 被别的设备导回来，而身份（`id`）、标签与时间戳全在 frontmatter 里——只写正文
   * 会导出一份「看起来一样但不认识」的笔记。
   *
   * 一篇走单文件保存，多篇由 `NoteTransfer.exportItems` 打包成 zip，这里不用分叉。
   */
  private exportSelected(): void {
    const targets = this.selectedNotes();
    if (targets.length === 0) {
      this.exitSelect();
      return;
    }
    const items: ExportItem[] = [];
    for (const note of targets) {
      items.push(new ExportItem(note.relPath, FrontmatterCodec.build(note)));
    }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    NoteTransfer.exportItems(context, items).then((result: TransferResult) => {
      Toast.show(this.getUIContext(), result.message);
      // 导出成功后退出多选；取消保存则留在原地，用户的勾选不该因为点了一下
      // 「取消」就全丢。
      if (result.ok) {
        this.exitSelect();
      }
    });
  }

  /** 长按菜单 › 导出 MD：单篇。 */
  private exportNote(note: Note): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    NoteTransfer.exportNote(context, note).then((result: TransferResult) => {
      Toast.show(this.getUIContext(), result.message);
    });
  }

  /** 长按菜单 › 创建副本。副本插在原笔记紧后面，所以刷新后两张卡相邻。 */
  private duplicateNote(note: Note): void {
    const copy = this.store.duplicateNote(note);
    this.refreshList();
    Toast.show(this.getUIContext(), `已创建「${copy.title}」`);
  }

  /**
   * 一条装着筛选项（或排序项）的胶囊。两条共用一行：左边筛选、右边排序。
   *
   * `base` 0 = 筛选，10 = 排序；`FilterChip` 把 `mode >= 10` 当排序，所以将来
   * 再加一组必须用 10 的倍数当 base。
   *
   * 表面走 `CapsuleSurface`：控件的原生沉浸光感（胶囊已经在标题栏底部那一带里，
   * 那里 `systemMaterial` 生效），不支持时退回手搓玻璃。**不要再给它套
   * `.clip(true)`**——材质的边缘光按节点自己的圆角栅格化，clip 会把矩形四条直边
   * 留成四道亮弧。
   */
  @Builder
  ChipGroup(base: number) {
    // `TopStart` 而不是 `Center`：滑块靠 `offset(x, y)` 定位，它需要一个从**左上角**
    // 起算的原点。居中栈里的 offset 是相对居中点算的，格号一换就偏半块板。
    // 三个子节点都是 100% 尺寸（或显式尺寸），改对齐不会挪动它们。
    Stack({ alignContent: Alignment.TopStart }) {
      this.CapsuleSurface(17)
      // 选中态那块会走的板子，压在材质之上、文字之下。
      this.ChipIndicator(base)
      Row({ space: 2 }) {
        if (base === 0) {
          // 三个筛选项统一 **2 字**（全部 / 收藏 / 归档）。三个 chip 是等分宽度的，
          // 字数一旦不等（「已归档」3 字夹在两个字中间），文字看起来就是一高一低，
          // 像没对齐。
          //
          // 顺序是 **全部 → 收藏 → 归档**，与「多少」无关，读的是使用频率：默认档
          // 在最左，收藏是日常翻得最多的一档，归档是一次性收起来的东西，放在最右。
          // `mode` 是 `filterMode` 的值而不是位置，所以这里**交换调用顺序就够了**，
          // 不需要改 `filterMode` 的语义（1 仍是归档、2 仍是收藏）。
          this.FilterChip('全部', 0)
          this.FilterChip('收藏', 2)
          this.FilterChip('归档', 1)
        } else {
          // 方向做进**当前档**的标签里（`标题 ↑`），与标签页的 `TagChip` 完全同款：
          // 点当前项翻转方向、点另一项换依据。另配一个箭头按钮的话，一行里要挤下
          // 三档 + 一个方向键，每一档都点不准。
          //
          // 三个排序项统一 **2 字**（`修改 / 标题 / 创建`）。去掉「按」的理由是它
          // 在三个词里信息量为零——这一整组本来就是排序条，每个词都隐含「按」；
          // 省下这个字之后，2 字与筛选项的 2 字对齐，左右两个胶囊的文字密度一致。
          //
          // 只传 base label，箭头由 `FilterChip` 在构建体内自己算——见 `chipText`。
          this.FilterChip('修改', 10)
          this.FilterChip('标题', 11)
          this.FilterChip('创建', 12)
        }
      }
      .width('100%')
      .height('100%')
      .padding(3)
    }
    .layoutWeight(1)
    .height(34)
    .borderRadius(17)
  }

  /**
   * Expanded search field. Shown in the title row in place of the title + search
   * circle, so it is one control rather than a duplicate of the button.
   *
   * Lives in the title bar, so it can use the platform immersive material like
   * `CircleAction` does. The `TextInput` inside keeps a transparent background —
   * a filled field would cover the material layer and defeat the point.
   */
  @Builder
  SearchField() {
    Stack({ alignContent: Alignment.Center }) {
      if (!this.immersiveSupported) {
        Column()
          .width('100%')
          .height('100%')
          .linearGradient({
            angle: 180,
            colors: [[$r('app.color.glass_hi'), 0.0], ['#00FFFFFF', this.glassSheenStop()]]
          })
      }
      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.magnifyingglass'))
          .fontSize(18)
          .fontColor([$r('app.color.text_secondary')])
        TextInput({ text: this.query, placeholder: '搜索标题、正文、标签' })
          .layoutWeight(1)
          .height(40)
          .id(SEARCH_INPUT_ID)
          .backgroundColor(Color.Transparent)
          .borderRadius(0)
          .padding({ left: 0, right: 0 })
          .fontSize(15)
          .placeholderColor($r('app.color.text_secondary'))
          .fontColor($r('app.color.text_primary'))
          .caretColor($r('app.color.text_primary'))
          .enterKeyType(EnterKeyType.Search)
          .onChange((value: string) => {
            this.query = value;
            // 搜索词改了就是另一次搜索：上一轮的「含归档」不能自动延续。
            this.includeArchived = false;
          })
          .onSubmit(() => {
            // 只有**提交过**的词才进历史。`onChange` 每敲一个字都会响，记下来
            // 的是「微」「微信」「微信 群」三条残句，历史会立刻变成垃圾。
            this.rememberSearch(this.query);
          })
      }
      .width('100%')
      .height(44)
      .padding({ left: 14, right: 6 })
    }
    .layoutWeight(1)
    .height(44)
    .borderRadius(22)
    // No `clip(true)`: it clips the material's rim to an inner rounded rect while
    // the material itself paints on the node's bounds, which is the same
    // four-arcs artefact the circular buttons had with `clipShape`. Nothing here
    // needs clipping — the children sit inside the 14/6 vp padding.
    .backgroundColor(Color.Transparent)
    .systemMaterial(this.immersiveSupported ? this.immersiveMaterial(true) : uiMaterial.Material.empty)
    .border(this.immersiveSupported
      ? { width: 0 }
      : { width: this.glassRimWidth(), color: $r('app.color.glass_border') })
    .backgroundEffect(this.immersiveSupported ? undefined : this.glassEffect())
  }

  /**
   * 最近搜索，挂在搜索框下面。
   *
   * 只在「查询为空」时出现：一旦开始打字，用户要的是结果，不是历史——列表在
   * 打字时还赖在页面上，会把第一屏结果挤下去。
   *
   * 点一条直接填进输入框，**不是**直接「用旧词搜一次」：填进去之后用户还能改，
   * 一次误触的代价只是清掉两个字。
   */
  @Builder
  SearchHistory() {
    Column({ space: 8 }) {
      Row() {
        Text('最近搜索')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
        Blank()
        Text('清空')
          .fontSize(12)
          .fontColor(this.accentColor())
          .padding({ left: 8, right: 2, top: 4, bottom: 4 })
          .onClick(() => {
            this.clearSearchHistory();
          })
          .accessibilityText('清空搜索历史')
      }
      .width('100%')

      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.searchHistory, (term: string) => {
          Text(term)
            .fontSize(12)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .borderRadius(14)
            .backgroundColor(this.accentChipColor())
            .margin({ right: 8, bottom: 8 })
            .onClick(() => {
              this.query = term;
              this.includeArchived = false;
            })
        }, (term: string) => `hist-${term}`)
      }
      .width('100%')
    }
    .width('100%')
    // 它是这一页的第一块内容，所以要自己顶开标题栏那道带子（含筛选条那一带，
    // 见 `titleBandHeight()`）。搜索框展开时顶栏一定在位——`hideTitleBar` 的条件
    // 里有 `!searchExpanded`——所以这里不需要判断 `chromeHidden`。
    .padding({ left: this.SIDE_INSET, right: this.SIDE_INSET,
      top: this.titleBandHeight() + 4, bottom: 0 })
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * Two logical chip groups share one builder: `mode` < 10 is the filter row
   * (全部/收藏/归档), `mode` >= 10 is the sort row (修改/标题/创建). Selected state
   * is a tinted wash + accent text, never a saturated accent block: a solid
   * accent fill inside a glass pill reads as a heavy slab.
   */
  @Builder
  FilterChip(label: string, mode: number) {
    Row({ space: 2 }) {
      Text(label)
        .fontSize(12)
        // **不变字重。** `fontWeight` 是离散属性，本来就没有中间帧——保留它等于
        // 在 260 ms 的滑动途中插一个瞬间的跳变，而且 Medium 的字宽比 Normal 略大，
        // 居中的标签会横向挪半个像素。选中的强调已经由「滑过来的板子 + 强调色文字」
        // 承担，再叠一个字重只会在切换的那一帧里出戏。
        // 颜色与位置的变化跟着板子一起走：少了这行 `animation`，板子滑过去了、
        // 文字却已经是新颜色，看起来像先点了再补动画。
        .fontColor(this.chipSelected(mode) ? this.accentColor() : $r('app.color.text_secondary'))
        .animation({ duration: 200, curve: Curve.FastOutSlowIn })
        .textAlign(TextAlign.Center)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      // 排序方向：**一个字形 + 旋转**，不是两个字形来回替换。
      //
      // 换字形会改字宽——箭头一出现标签就被推开一格，这一下跳动比颜色变化显眼得多。
      // 旋转同一个 `↓`（升序转到 180° 就是 `↑`）宽度恒定，中途经过 `→` 也读得懂。
      //
      // 节点**始终存在**（未选中时 `opacity(0)`），不是 `if` 包起来：排序组三个
      // chip 都留出同样的箭头位，未选中项的文字才和选中项对齐在同一条中轴上。
      if (mode >= 10) {
        Text('↓')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.accentColor())
          .rotate({ angle: this.sortDesc ? 0 : 180 })
          .opacity(this.sortMode === mode - 10 ? 1 : 0)
          .animation({ duration: 220, curve: Curve.FastOutSlowIn })
      }
    }
    .layoutWeight(1)
    .height(28)
    .borderRadius(14)
    .justifyContent(FlexAlign.Center)
    // 选中底色由 `ChipIndicator` 那一条会滑动的板子承担，这里永远透明——
    // 两边都画的话，滑动途中会出现「两块板」的鬼影。
    .backgroundColor(Color.Transparent)
    .onClick(() => {
      if (mode < 10) {
        this.filterMode = mode;
        // 换筛选档 = 换一个问题，「含归档」是上一个问题上的决定。
        this.includeArchived = false;
      } else {
        this.onSortChipTap(mode - 10);
      }
    })
    .accessibilityText(this.chipText(label, mode))
  }

  /**
   * 药丸的**无障碍文字**。屏幕上不再拼接箭头——箭头是一个常驻的旋转节点
   * （见 `FilterChip`），但读屏没有旋转，所以这里把方向说全。
   *
   * 读的是 `this.sortMode` / `this.sortDesc`，调用点是 `.accessibilityText(...)`
   * ——`@Builder` 的构建体内部。把结果当参数传进来
   * （`this.FilterChip(this.sortLabel(...), 10)`）只在调用处求值一次，`@Local`
   * 读的不是被构建节点的依赖，于是列表换成了标题序、标签却还说「修改 ↓」（实测）。
   */
  private chipText(label: string, mode: number): string {
    if (mode < 10 || this.sortMode !== mode - 10) {
      return label;
    }
    return `${label} ${this.sortDesc ? '↓' : '↑'}`;
  }

  /**
   * 排序项的点击：点当前项翻转升降序，点另一项换依据并回到该依据的自然方向。
   *
   * 与标签页 `onTagChipTap` 同一套规则——两个页面的排序控件外观一致，行为也必须
   * 一致，否则用户在两个页面学到的是两种手感。
   */
  private onSortChipTap(mode: number): void {
    if (this.sortMode === mode) {
      this.sortDesc = !this.sortDesc;
      return;
    }
    this.sortMode = mode;
    this.sortDesc = this.sortDefaultDesc(mode);
  }

  private chipSelected(mode: number): boolean {
    return mode < 10 ? this.filterMode === mode : this.sortMode === mode - 10;
  }

  // ------------------------------------------------------------ chip metrics
  //
  // 滑动指示器要落在「某一格」上，所以必须知道格子的真实宽度——**不能用百分比
  // 位移**。`offset` 的百分比是相对**自身**宽度，不是相对父容器（第一次改就是这么
  // 错的：33.33% 位移等于把板子挪三分之一块板，看起来像卡住不动）。
  //
  // 几何与 `TitleBottom` 的布局一一对应：整宽减去两侧 `SIDE_INSET`，两条胶囊之间
  // 一道 8 vp 的缝，各占一半。

  /** 页面可用宽度（vp），与 `columnWidth()` 取自同一个 display。 */
  private contentWidthVp(): number {
    const d = display.getDefaultDisplaySync();
    return d.width / d.densityPixels;
  }

  /** 一条胶囊的外宽：`(可用宽 − 两侧内缩 − 中间那道 8)` 的一半。 */
  private capsuleWidth(): number {
    return (this.contentWidthVp() - this.SIDE_INSET * 2 - 8) / 2;
  }

  /** 胶囊内一格的宽度：先扣 3 vp 内边距（两侧），再按 chip 间距 2 vp 均分。 */
  private chipSlotWidth(count: number): number {
    const inner: number = this.capsuleWidth() - 6;
    return (inner - 2 * (count - 1)) / count;
  }

  /** 第 `index` 格的左沿（相对胶囊左上角）。 */
  private chipOffsetX(index: number, count: number): number {
    return 3 + index * (this.chipSlotWidth(count) + 2);
  }

  /**
   * 当前选中的是第几格（视觉顺序，不是 `mode`）。
   *
   * 筛选项的 `mode` 是 `filterMode` 的语义值：0 全部 / 2 收藏 / 1 归档，而屏幕上
   * 的顺序是 全部(0) 收藏(2) 归档(1)——所以这里是一张映射表，不是恒等。
   */
  private chipIndex(base: number): number {
    if (base === 0) {
      if (this.filterMode === 0) {
        return 0;
      }
      return this.filterMode === 2 ? 1 : 2;
    }
    return this.sortMode;
  }

  private chipCount(base: number): number {
    return 3;
  }

  /**
   * 选中态的那块板子：**一个**圆角块在三格之间平移。
   *
   * 这是「切换生硬」的真正解法。从前选中态由每个 chip 自己的 `backgroundColor`
   * 承担，切换就是两块板各自淡入淡出——两个互不相干的 160 ms 交叉淡入，读起来
   * 只能像「闪一下」。换成一块会走的板之后，切换是「移过去」，位移本身携带了
   * 「从哪到哪」的信息，这是淡入淡出给不了的。
   *
   * 三个约束：
   *  - **`base` 是唯一入参，格号在构建体内部算。** 传 `this.chipIndex(base)` 进来
   *    只在调用处求值一次，`@Local` 的读取不构成被构建节点的依赖，板子就不会动
   *    （与 `chipText` 同一个坑，实测过）。
   *  - **chip 自己不带底色**，否则滑动途中会看到两块板。
   *  - **位移量必须是绝对值，不能是百分比。** `offset` 的百分比是相对**自身**宽度
   *    算的，一格 33% 的位移只把板子挪三分之一块板自己，看起来像卡住不动（第一版
   *    就是这么错的）。格宽由 `chipSlotWidth()` 从 display 反推，屏宽一变就跟着变，
   *    所以平板/折叠屏也不用另设一套。
   *  - 时长 260 ms 比文字的 200 ms 略长：文字先到位、板子压着尾音落下，比两者同时
   *    停住更像一件东西被推过去。
   */
  @Builder
  ChipIndicator(base: number) {
    Column()
      .width(this.chipSlotWidth(this.chipCount(base)))
      .height(28)
      .borderRadius(14)
      .backgroundColor(this.accentChipColor())
      .offset({ x: this.chipOffsetX(this.chipIndex(base), this.chipCount(base)), y: 3 })
      .animation({ duration: 260, curve: Curve.FastOutSlowIn })
  }

  /**
   * Active chip index within a TagChipGroup (0..1).
   */
  private tagChipIndex(kind: number): number {
    if (kind === 0) {
      return this.tagSortKey;
    }
    return this.tagFilter;
  }

  /**
   * 标签页的滑块。
   *
   * 标签页的每条胶囊只有 **2 格**（名称/数量、全部/在用），格宽与笔记页同源
   * （`chipSlotWidth(2)`），所以两个页面的板子一样宽、一样高、走同一条曲线。
   * 页面切换时不能换手感——这是同一套控件。
   */
  @Builder
  TagChipIndicator(kind: number) {
    Column()
      .width(this.chipSlotWidth(this.tagChipCount()))
      .height(28)
      .borderRadius(14)
      .backgroundColor(this.accentChipColor())
      .offset({ x: this.chipOffsetX(this.tagChipIndex(kind), this.tagChipCount()), y: 3 })
      .animation({ duration: 260, curve: Curve.FastOutSlowIn })
  }

  private tagChipCount(): number {
    return 2;
  }

  /**
   * 搜索结果的提示：命中的笔记里有被归档的，那些默认不出现在结果里。
   *
   * 三件事必须成立：
   *
   *  1. **默认不混进来。** 归档是用户主动做的分类动作，一次搜索就把收起来的东西
   *     全倒出来，等于归档没生效。
   *  2. **不能只说「没找到」。** 用户记得那条笔记存在，静默地搜不到只会让人以为
   *     笔记丢了。
   *  3. **必须窄、必须让开键盘。** 这一条原来是一整张卡片：横贯两列、两行字、
   *     带图标和按钮，在键盘弹起时被顶出屏幕，等于没有。现在是一行文字 +
   *     一个动词，贴在**筛选条下面**（见 `NotesPage`），那是键盘永远碰不到的
   *     位置——页底会随键盘上移，而页顶不会。
   *
   * 位置在滚动区**外面**：`WaterFlow` 的 `FlowItem` 不能跨列，一条横贯两列的
   * 提示塞进去会被压成一列宽。
   *
   * `includeArchived` 打开后这一条变成「收起」——否则用户被留在全量结果里，
   * 没有任何地方能回到默认视图。
   */
  @Builder
  ArchivedSearchHint() {
    Row() {
      Row({ space: 6 }) {
        SymbolGlyph($r('sys.symbol.archivebox'))
          .fontSize(12)
          .fontColor([$r('app.color.text_secondary')])
        Text(this.includeArchived ? '已含归档' : '已归档中还有匹配')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
        Text(this.includeArchived ? '收起' : '查看')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.accentColor())
          .maxLines(1)
      }
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .background(this.SettingsCardSurface(), CARD_BG_OPTIONS)
      .borderRadius(this.cardCorner)
      .onClick(() => {
        this.includeArchived = !this.includeArchived;
      })
      .accessibilityText(this.includeArchived ? '收起已归档的搜索结果' : '在已归档中搜索')
    }
    // 宽度撑满只为了居中；胶囊本身是内容宽的——一条横贯全屏的窄带仍然会被
    // 读成「一条横幅」，而它其实只是一句补充说明。
    .width('100%')
    .justifyContent(FlexAlign.Center)
    // 与下面的网格之间留一点气，否则胶囊会贴着第一排卡片。
    .padding({ bottom: 8 })
  }

  /**
   * 空列表的说明。
   *
   * 三种空法说三件事，不能共用一句话：搜不到（换词）、归档区空（这里本来就可能
   * 什么都没有，指引「点 +」会把人送去新建，而不是去归档）、真的一篇都没有
   * （这才是该引导新建的时候）。共用一个「点击右上角 + 记录第一条」时，空的
   * 「已归档」看起来像是在暗示「你还没新建过笔记」。
   *
   * 构建体已换成共用组件 `components/ui/EmptyState`，视觉与原来逐字一致；
   * `emptyIcon()` / `emptyTitle()` / `emptyHint()` 三个方法留在这里，因为它们是本页的
   * 业务语义（搜不到 / 归档空 / 一篇都没有），属于页面而不属于控件。
   */
  @Builder
  EmptyState() {
    EmptyState({
      icon: this.emptyIcon(),
      title: this.emptyTitle(),
      hint: this.emptyHint(),
      fill: true
    })
  }

  private emptyIcon(): Resource {
    if (this.query.trim().length === 0 && this.filterMode === 1) {
      return $r('sys.symbol.archivebox');
    }
    return $r('sys.symbol.doc_text');
  }

  private emptyTitle(): string {
    if (this.query.trim().length > 0) {
      return '没有匹配的笔记';
    }
    if (this.filterMode === 1) {
      return '还没有归档的笔记';
    }
    if (this.filterMode === 2) {
      return '还没有收藏的笔记';
    }
    return '还没有笔记';
  }

  private emptyHint(): string {
    if (this.query.trim().length > 0) {
      return '换个关键词试试';
    }
    if (this.filterMode === 1) {
      return '在笔记卡片上右滑，轻滑一下即可归档';
    }
    if (this.filterMode === 2) {
      return '在笔记卡片上左滑，轻滑一下即可收藏';
    }
    return '点击右上角 + 记录第一条';
  }

  // ----------------------------------------------------------------- tags

  @Builder
  TagsPage() {
    Column({ space: 12 }) {
      if (this.store.tags.length === 0) {
        // 空态换成共用组件：原来是一行 13 灰字，与笔记页的三段式（图标 / 标题 /
        // 提示）完全不是一种东西——同一页签栏下的两页，「没有内容」说成两种样子。
        // 图标用 `sys.symbol.label`（标签页自己的符号），不借用笔记页的 `doc_text`。
        EmptyState({
          icon: $r('sys.symbol.label'),
          title: '还没有标签',
          hint: '在笔记 frontmatter 里添加 tags 字段后会自动出现在这里。',
          fill: true
        })
      } else {
        // 排序与筛选**不在这里**：它们和笔记页那两条一样住在标题栏底部
        // （`TitleBottom`），所以两页的控件不只是长得一样，而是同一个构建体。
        // 有标签时 `bandInset` 是 50，标签全删之后它会走到 0——标题栏里就不留
        // 空带了。
        //
        // 没有 HDS 标题栏时（API < 23）无处可搬，这里自己画一条——降级是「材质
        // 差一点」，不是「功能没了」。
        if (!this.hdsSupported) {
          Row({ space: 8 }) {
            this.TagChipGroup(1)
            this.TagChipGroup(0)
          }
          .width('100%')
          .padding({ left: this.SIDE_INSET, right: this.SIDE_INSET })
        }

        // 标签是**药丸**，不是等长的列表行：长度由名字自己决定，从左到右、从上
        // 到下流式排布。等长行会让人以为每一行是一个「条目」，而标签本质上是
        // 一堆可以一眼扫完的关键词。
        Scroll(this.tagsScroller) {
          Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Start }) {
            ForEach(this.visibleTags(), (tag: string) => {
              this.TagPill(tag)
            }, (tag: string) => `pill-${tag}-${this.store.countTag(tag)}`)
          }
          .width('100%')
          .padding({ left: this.SIDE_INSET, right: this.SIDE_INSET })
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        // `Scroll` 的子节点默认**垂直居中**（`align` 的默认值），只有一颗标签时
        // 药丸会飘在屏幕正中。标签是从上往下读的，必须顶到上沿。
        .align(Alignment.TopStart)
        // 与笔记页一致：底部留出浮动页签栏的高度，否则最后一排药丸被压在栏下。
        .contentEndOffset(120)
        // 与笔记页、设置页同一套让位判定（上滑收起、回顶恢复）。
        .onDidScroll(() => {
          this.handleChromeScroll(this.tagsScroller);
        })
        // 顶栏收起后药丸会滚到状态栏下沿被直线裁掉，与笔记网格同一个问题、
        // 同一条渐隐。
        .fadingEdge(true, { fadingEdgeLength: LengthMetrics.vp(CHROME_FADE) })
      }
    }
    .width('100%')
    .height('100%')
    // No local heading: the HDS title bar owns the page title (大标题) on every
    // tab, so each tab only reserves that band — which now includes the filter
    // row it carries.
    .padding({ top: this.pageTopInset() })
    .bindSheet(this.tagNameShown, this.TagNameSheet(), {
      height: SheetSize.MEDIUM,
      dragBar: true,
      showClose: false,
      backgroundColor: $r('app.color.page_bg'),
      onDisappear: () => {
        this.tagNameShown = false;
      }
    })
  }

  /**
   * 长按标签卡片弹出的菜单。
   *
   * 两件事：**修改**（改名，作用在所有用到它的笔记上）、**删除**（把标签从所有
   * 笔记里去掉）。
   *
   * 删除**不删笔记**——笔记还在，只是没有这个标签了。所以确认框里要说清楚，
   * 否则「删除」两个字会让人以为内容要没了。
   */
  @Builder
  TagMenu(tag: string) {
    Menu() {
      MenuItem({ content: '修改' })
        .contentFontColor($r('app.color.text_primary'))
        .onClick(() => {
          this.openTagNameEditor(true, tag);
        })
      MenuItem({ content: '删除' })
        .contentFontColor($r('app.color.danger'))
        .onClick(() => {
          this.confirmRemoveTag(tag);
        })
    }
  }

  /** 删除标签：只从笔记里去掉这个标签，笔记本身不动。 */
  private confirmRemoveTag(tag: string): void {
    const count = this.store.countTag(tag);
    Dialogs.danger(this.getUIContext(), '删除标签',
      count > 0 ? `「${tag}」会从 ${count} 篇笔记里去掉。这些笔记不会被删除。` : `「${tag}」会被删除。`,
      '删除', () => {
        this.store.removeTag(tag);
        TagStore.instance.removeTag(tag);
        this.refreshList();
        Toast.show(this.getUIContext(), '标签已删除');
      });
  }

  /**
   * 新建 / 修改标签名的输入面板。
   *
   * 新建出来的标签暂时没有笔记用它，它会出现在标签页里，等用户在笔记的「标签…」
   * 里选中它。名字是普通文本，**不**自动加 `#`——标签在 frontmatter 里本来就不带
   * `#`，显示时才加。
   */
  private openTagNameEditor(isRename: boolean, tag: string): void {
    this.tagNameMode = isRename ? 1 : 0;
    this.tagNameTarget = tag;
    this.tagNameInput = tag;
    this.tagNameShown = true;
  }

  private commitTagName(): void {
    const name = this.tagNameInput.trim().replace(/^#+/, '').replace(/\s+/g, ' ').trim();
    if (name.length === 0) {
      this.tagNameShown = false;
      return;
    }
    if (this.tagNameMode === 1) {
      const old = this.tagNameTarget;
      if (name === old) {
        this.tagNameShown = false;
        return;
      }
      const changed = this.store.renameTag(old, name);
      TagStore.instance.renameTag(old, name);
      this.refreshList();
      this.tagNameShown = false;
      Toast.show(this.getUIContext(), changed > 0 ? `已改名，影响 ${changed} 篇笔记` : '已改名');
      return;
    }
    if (TagStore.instance.addTag(name)) {
      this.tagNameShown = false;
      // 新标签只存在于标签名录里，笔记的标签列表没变，所以必须显式刷新快照。
      this.refreshList();
      Toast.show(this.getUIContext(), '标签已创建，可在笔记的「标签…」里使用');
      return;
    }
    Toast.show(this.getUIContext(), '这个标签已经有了');
  }

  @Builder
  TagNameSheet() {
    Column({ space: 12 }) {
      Row() {
        Text(this.tagNameMode === 1 ? '修改标签' : '新建标签')
          .fontSize(20)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        Blank()
        Text('完成')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.accentColor())
          .padding({ left: 12, right: 4, top: 6, bottom: 6 })
          .onClick(() => {
            this.commitTagName();
          })
      }
      .width('100%')

      TextInput({ text: this.tagNameInput, placeholder: '标签名' })
        .width('100%')
        .height(44)
        .fontSize(15)
        .backgroundColor($r('app.color.card_bg'))
        .borderRadius(12)
        .padding({ left: 12, right: 12 })
        .fontColor($r('app.color.text_primary'))
        .placeholderColor($r('app.color.text_secondary'))
        .caretColor(this.accentColor())
        .onChange((value: string) => {
          this.tagNameInput = value;
        })
        .onSubmit(() => {
          this.commitTagName();
        })

      Text(this.tagNameMode === 1
        ? '改名会同时作用在所有用到这个标签的笔记上。'
        : '创建后可以在笔记的长按菜单「标签…」里选用它。')
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
    }
    .width('100%')
    .padding({ left: this.SIDE_INSET, right: this.SIDE_INSET, top: 16, bottom: 24 })
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 标签页的胶囊组：0 = 排序，1 = 筛选。
   *
   * 与笔记页的 `ChipGroup` 同一套外壳（材质 + 遮罩 + 34 vp + 圆角 17），
   * 所以两个页面的筛选条长得一模一样。摆放顺序也一致：先筛选、后排序。
   */
  @Builder
  TagChipGroup(kind: number) {
    // 与 `ChipGroup` 同一个理由用 `TopStart`：滑块按左上角 + offset 定位。
    Stack({ alignContent: Alignment.TopStart }) {
      this.CapsuleSurface(17)
      this.TagChipIndicator(kind)
      Row({ space: 2 }) {
        if (kind === 0) {
          // 只传基础文字，箭头在 `TagChip` 的构建体内算（同 `FilterChip.chipText`）：
          // `@Builder` 的参数按值传，在外面算好再传进来，「箭头」就不会随
          // `tagSortKey` / `tagSortDesc` 重绘——实测点「数量」后列表已按数量重排，
          // 标签却还写着「名称 ↑」。
          this.TagChip('名称', 0, 0)
          this.TagChip('数量', 0, 1)
        } else {
          // 两个筛选项统一 **2 字**（全部 / 在用）。「有笔记」是 3 字，夹在「全部」
          // 旁边会让两个等分 chip 的文字看起来不一样宽；「在用」与它的含义一致
          // （名录里建了但没有任何笔记使用的标签不算），也更短。
          this.TagChip('全部', 1, 0)
          this.TagChip('在用', 1, 1)
        }
      }
      .width('100%')
      .height('100%')
      .padding(3)
    }
    .layoutWeight(1)
    .height(34)
    .borderRadius(17)
  }

  /**
   * 标签页的药丸。外观与笔记页的 `FilterChip` 一致：28 vp 高、圆角 14、
   * 选中是强调色浅底 + 强调色文字（不是实心色块——玻璃胶囊里的实心色块很重）。
   *
   * 排序项的方向做进标签里（`名称 ↑`）：点当前项翻转升降序，点另一项切换
   * 排序依据。方向另配一个箭头键的话，一行里要放三组控件，挤在一起点不准。
   */
  @Builder
  TagChip(label: string, group: number, index: number) {
    Row({ space: 2 }) {
      Text(label)
        .fontSize(12)
        // 与 `FilterChip` 同一条规则：不动字重。`fontWeight` 没有中间帧，在滑动
        // 途中插一个瞬间跳变，还会因为 Medium 略宽而让居中标签横向挪一下。
        .fontColor(this.tagChipSelected(group, index) ? this.accentColor() : $r('app.color.text_secondary'))
        .animation({ duration: 200, curve: Curve.FastOutSlowIn })
        .textAlign(TextAlign.Center)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      // 与 `FilterChip` 同一条规则：一个字形 + 旋转，节点常驻、未选中时透明。
      // 换字形会改字宽，标签被推开一格；宽度恒定才谈得上「不跳」。
      if (group === 0) {
        Text('↓')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.accentColor())
          .rotate({ angle: this.tagSortDesc ? 0 : 180 })
          .opacity(this.tagSortKey === index ? 1 : 0)
          .animation({ duration: 220, curve: Curve.FastOutSlowIn })
      }
    }
    .layoutWeight(1)
    .height(28)
    .borderRadius(14)
    .justifyContent(FlexAlign.Center)
    // 选中底色由 `TagChipIndicator` 那块会走的板子承担，chip 自己永远透明。
    .backgroundColor(Color.Transparent)
    .onClick(() => {
      this.onTagChipTap(group, index);
    })
    .accessibilityText(this.tagChipText(label, group, index))
  }

  /**
   * 标签页药丸的**无障碍文字**：未选中时只是标签，选中时带上方向。
   *
   * 必须在 `TagChip` 的构建体内调用——与 `chipText` 同一个理由：`@Builder` 的
   * 参数按值传，方向在外面算出来就不会随排序状态重绘。
   */
  private tagChipText(label: string, group: number, index: number): string {
    if (group !== 0 || this.tagSortKey !== index) {
      return label;
    }
    return `${label} ${this.tagSortDesc ? '↓' : '↑'}`;
  }

  private tagChipSelected(group: number, index: number): boolean {
    if (group === 0) {
      return this.tagSortKey === index;
    }
    return this.tagFilter === index;
  }

  private onTagChipTap(group: number, index: number): void {
    if (group === 1) {
      this.tagFilter = index;
      return;
    }
    if (this.tagSortKey === index) {
      this.tagSortDesc = !this.tagSortDesc;
      return;
    }
    this.tagSortKey = index;
    this.tagSortDesc = false;
  }

  /**
   * 当前要显示的标签，按排序整理后按搜索词过滤。
   *
   * 「按名称」用 `localeCompare`，与 `NoteStore.collectTags()` 的默认排序一致，
   * 所以切到按名称升序时顺序不会突然变一次。
   *
   * 筛选「在用」剔掉只在名录里、没有任何笔记使用的标签。之前这一档是「置顶」，
   * 置顶功能已经整体移除；这里改成「在用」而不是干脆删掉这一档，是因为名录里
   * 确实会有建了还没用上的标签，而它们和真正在用的标签混在一起时，标签页没法回答
   * 「哪些标签是我真的在用的」。
   */
  private visibleTags(): string[] {
    let result: string[] = this.tagsSnapshot.slice();
    if (this.tagFilter === 1) {
      result = result.filter((tag: string) => this.store.countTag(tag) > 0);
    }
    this.sortTags(result);
    const keyword: string = this.query.trim().toLowerCase();
    if (keyword.length > 0) {
      result = result.filter((tag: string) => tag.toLowerCase().includes(keyword));
    }
    return result;
  }

  private sortTags(tags: string[]): void {
    if (this.tagSortKey === 1) {
      tags.sort((a: string, b: string): number => this.store.countTag(a) - this.store.countTag(b));
    } else {
      tags.sort((a: string, b: string): number => a.localeCompare(b));
    }
    if (this.tagSortDesc) {
      tags.reverse();
    }
  }

  // ------------------------------------------------------------ tag pills

  /** 全场最高的标签笔记数。热度档位是**相对**的，这是唯一稳定的参照系。 */
  private tagMaxCount(): number {
    let max: number = 0;
    for (const tag of this.tagsSnapshot) {
      const count = this.store.countTag(tag);
      if (count > max) {
        max = count;
      }
    }
    return max;
  }

  /**
   * 一颗标签药丸。
   *
   * 三个决定：
   *
   * 1. **宽度由内容决定，不设 `layoutWeight`。** 这正是「不等长」的含义——标签是
   *    关键词，数量和长度本身就是信息；等长行会把它读成一份列表。
   * 2. **表面是 `MaterialLayer` 承载的**，不是 `.systemMaterial()`：页面内容区不在
   *    沉浸光感允许的范围内（同一个原因见 `ChipGroup` 的注释）。材质之上压一层
   *    该标签热度的浅色遮罩，色相从蓝到红随笔记数量走。
   * 3. **颗数写在药丸里**（`# 工作 12`）。它是色相的依据，不写出来用户只能猜为什么
   *    这颗是红的——色相不该是唯一的信息通道。
   */
  @Builder
  TagPill(tag: string) {
    // 表面必须走 `.background(builder)`，**不能**做成 Stack 的兄弟节点。
    // `MaterialLayer` 用 `LayoutPolicy.matchParent` 定尺寸：在 Stack 里它按「可用
    // 空间」解析，于是一颗药丸会撑满整个滚动区（实测：一颗 `# Markdowns` 占了
    // 48…1248 × 450…2208 的整块）。`.background()` 是拿节点已经量好的盒子去排，
    // 尺寸无从被它影响——这与笔记卡片踩的是同一个坑。
    Row({ space: 6 }) {
      Text(`# ${tag}`)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.tagHeatHue(tag))
        .maxLines(1)
      Text(`${this.store.countTag(tag)}`)
        .fontSize(11)
        .fontColor(this.tagHeatHue(tag))
        .opacity(0.75)
    }
    .padding({ left: 14, right: 14, top: 8, bottom: 8 })
    .background(this.TagPillSurface(tag), CARD_BG_OPTIONS)
    .borderRadius(16)
    .border({ width: 1, color: this.tagHeatBorder(tag) })
    // 材质画在 `backgroundColor` 之上、子节点之下，所以遮罩是 builder 里的第二层，
    // 不是这颗 Row 的 backgroundColor（那会盖住材质）。
    .backgroundColor(Color.Transparent)
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.95 })
    .onClick(() => {
      this.filterByTag(tag);
    })
    .bindContextMenu(this.TagMenu(tag), ResponseType.LongPress, {
      preview: MenuPreviewMode.NONE
    })
    .accessibilityText(`标签 ${tag}，${this.store.countTag(tag)} 篇笔记`)
    .margin({ right: 8, bottom: 8 })
  }

  /**
   * 药丸的表面：沉浸光感承载层 + 这一档热度的浅色遮罩。
   *
   * 与 `CardSurface` 同构（carrier 在下、遮罩在上），区别只在遮罩的色相与圆角：
   * 卡片是一个应用同一套表面，标签药丸要按热度换色。
   */
  @Builder
  TagPillSurface(tag: string) {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.glassOn()) {
        MaterialLayer({
          radius: 16,
          gear: this.glassLevel
        })
      }
      Column()
        .width('100%')
        .height('100%')
        .borderRadius(16)
        .backgroundColor(this.glassOn() ? this.tagHeatTint(tag) : this.tagHeatOpaque(tag))
    }
    .width('100%')
    .height('100%')
  }

  /** 这颗药丸的档位（0 冷 … 3 热）。 */
  private tagBucket(tag: string): number {
    return TagHeat.bucket(this.store.countTag(tag), this.tagMaxCount());
  }

  private tagHeatHue(tag: string): string {
    return TagHeat.hue(this.tagBucket(tag), this.activeDark());
  }

  /** 药丸底色：同一路色相的极低不透明度，让材质仍然透出来。 */
  private tagHeatTint(tag: string): string {
    const alpha: number = this.activeDark() ? 0.20 : 0.13;
    return Index.withAlpha(this.tagHeatHue(tag), alpha);
  }

  /**
   * 没有沉浸光感时的药丸底色。
   *
   * 不能复用 `tagHeatTint`：那个 13% 的色相是**压在材质上**的一层，直接铺在页面
   * 背景下会淡到看不出这颗药丸在哪一档（材质的模糊与折射提供了大部分的「板」）。
   * 没有材质时药丸得自己成为一块板，所以不透明度高得多。
   */
  private tagHeatOpaque(tag: string): string {
    const alpha: number = this.activeDark() ? 0.24 : 0.16;
    return Index.withAlpha(this.tagHeatHue(tag), alpha);
  }

  private tagHeatBorder(tag: string): string {
    const alpha: number = this.activeDark() ? 0.28 : 0.18;
    return Index.withAlpha(this.tagHeatHue(tag), alpha);
  }

  /**
   * `#RRGGBB` → 带指定不透明度的 `#AARRGGBB`。
   *
   * 必须自己算：`Color.Transparent` 在非预乘插值里会往黑里沉（露出一道灰），而
   * `$r()` 拿不到 hex。与 `NoteCard.withAlpha` 是同一个理由，两份实现是因为它们的
   * 输入（资源色 vs 运行期 hex）不同，各自只需处理自己那一种。
   */
  private static withAlpha(hex: string, alpha: number): string {
    const a: number = Math.round(Math.max(0, Math.min(1, alpha)) * 255);
    const aHex: string = a.toString(16).padStart(2, '0').toUpperCase();
    if (hex.length === 9 && hex.startsWith('#')) {
      return '#' + aHex + hex.substring(3);
    }
    if (hex.length === 7 && hex.startsWith('#')) {
      return '#' + aHex + hex.substring(1);
    }
    return hex;
  }

  // -------------------------------------------------------------- settings

  @Builder
  SettingsPage() {
    Column({ space: 12 }) {
      List({ space: 8, scroller: this.settingsScroller }) {
        ListItem() {
          this.SectionLabel('阅读与编辑')
        }

        ListItem() {
          // 编辑这一组放在**同一个卡片**里：编辑体验 / 格式按钮条 / 字号 / 行距 /
          // 圆角都是「写东西时的样子」，拆成单行卡片会让它们看起来像互不相干的
          // 开关，而实际上它们互相影响（格式按钮条只在编辑界面里有意义）。
          Column({ space: 12 }) {
            Row() {
              Column({ space: 2 }) {
                Text('编辑体验')
                  .fontSize(16)
                  .fontColor($r('app.color.text_primary'))
                Text(this.simpleEditing ? '整篇输入，像记事本' : '点哪一块改哪一块')
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
              }
              .alignItems(HorizontalAlign.Start)

              Blank()

              Row({ space: 2 }) {
                this.SegmentButton('简单', 0, SEG_EDIT)
                this.SegmentButton('分块', 1, SEG_EDIT)
              }
              .padding(3)
              .borderRadius(14)
              .backgroundColor($r('app.color.page_bg'))
            }
            .width('100%')

            Row() {
              Column({ space: 2 }) {
                Text('格式按钮条')
                  .fontSize(16)
                  .fontColor($r('app.color.text_primary'))
                Text('粗体、列表、待办这些按钮')
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
              }
              .alignItems(HorizontalAlign.Start)

              Blank()

              Toggle({ type: ToggleType.Switch, isOn: this.showFormatBar })
                .selectedColor(this.accentColor())
                .onChange((on: boolean) => {
                  this.setFormatBar(on);
                })
            }
            .width('100%')

            // 字号与行距压成**一行一条**：标签、���块、数值并排。
            //
            // 原来每项是两行（标题 + 数值）再跟一条滑块，三项就吃掉一屏多，
            // 设置页大半被滑块占满。滑块本身够宽，标签和数值都可以让位给它。
            Row({ space: 10 }) {
              Text('字号')
                .fontSize(14)
                .fontColor($r('app.color.text_primary'))
                .width(40)
              Slider({
                value: this.fontSize,
                min: FONT_SIZE_MIN,
                max: FONT_SIZE_MAX,
                step: 1,
                style: SliderStyle.OutSet
              })
                .layoutWeight(1)
                .selectedColor(this.accentColor())
                .blockColor(this.accentColor())
                .trackColor($r('app.color.divider'))
                .onChange((value: number) => {
                  this.fontSize = Math.round(value);
                  SettingsStore.instance.setEditorFontSize(this.fontSize);
                })
              Text(`${this.fontSize} px`)
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
                .width(48)
                .textAlign(TextAlign.End)
            }
            .width('100%')

            Row({ space: 10 }) {
              Text('行距')
                .fontSize(14)
                .fontColor($r('app.color.text_primary'))
                .width(40)
              Slider({
                // 必须喂给滑块**范围之内**的值。
                //
                // 只靠 `SettingsStore` 在读取时钳制是不够的：一旦存储里的旧值落在
                // 新范围之外（把范围改成 0.75–1.50 之后，原来的 1.55 就在外面），
                // 滑块会把它自己的解读写回 `onChange`，于是用户没碰过的设置被
                // 静默改掉——实测行距从 1.55 变成了 1.10。
                value: this.clampLineHeight(this.lineHeight),
                min: LINE_HEIGHT_MIN,
                max: LINE_HEIGHT_MAX,
                step: 5,
                style: SliderStyle.OutSet
              })
                .layoutWeight(1)
                .selectedColor(this.accentColor())
                .blockColor(this.accentColor())
                .trackColor($r('app.color.divider'))
                .onChange((value: number) => {
                  this.lineHeight = Math.round(value);
                  SettingsStore.instance.setEditorLineHeight(this.lineHeight);
                })
              Text(`${(this.lineHeight / 100).toFixed(2)} 倍`)
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
                .width(48)
                .textAlign(TextAlign.End)
            }
            .width('100%')
          }
          .width('100%')
          .padding(14)
          .background(this.SettingsCardSurface(), CARD_BG_OPTIONS)
          .backgroundColor(Color.Transparent)
          .borderRadius(this.cardCorner)
        }

        ListItem() {
          this.SectionLabel('外观')
        }

        ListItem() {
          Column({ space: 12 }) {
            Row() {
              Column({ space: 2 }) {
                Text('外观')
                  .fontSize(16)
                  .fontColor($r('app.color.text_primary'))
                Text('跟随系统或手动固定')
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
              }
              .alignItems(HorizontalAlign.Start)

              Blank()

              Row({ space: 2 }) {
                this.SegmentButton('跟随系统', 0)
                this.SegmentButton('浅色', 1)
                this.SegmentButton('深色', 2)
              }
              .padding(3)
              .borderRadius(14)
              .backgroundColor($r('app.color.page_bg'))
            }
            .width('100%')

            Row() {
              Column({ space: 2 }) {
                Text('沉浸光感挡位')
                  .fontSize(16)
                  .fontColor($r('app.color.text_primary'))
                Text(`本机${this.deviceTierLabel()} · 自适应优先`)
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
              }
              .alignItems(HorizontalAlign.Start)

              Blank()

              Row({ space: 2 }) {
                this.SegmentButton('自适应', GEAR_ADAPTIVE, SEG_GLASS)
                this.SegmentButton('高', GEAR_HIGH, SEG_GLASS)
                this.SegmentButton('中', GEAR_MEDIUM, SEG_GLASS)
                this.SegmentButton('低', GEAR_LOW, SEG_GLASS)
              }
              .padding(3)
              .borderRadius(14)
              .backgroundColor($r('app.color.page_bg'))
            }
            .width('100%')

            // 背景主题是**外观里唯一的一档色相选择**。强调色（按钮、标签、选中态）
            // 由它派生，所以这里不再有第二行色板——两个开关会互相打架：选沙海却
            // 留着黄山那套蓝按钮，背景与前景就是两套不相干的色相，「自动适配」也
            // 成了一句做不到的承诺。
            //
            // 副标题给的是地貌而不是色名：五个主题的底色都很接近，用户在设置页
            // 分辨它们靠的是「密而陡 / 舒展的同心弧 / 一圈圈闭合」这些形状描述。
            // 不把强调色名也塞进来——五个点已占 194 vp，文字列只剩约 186 vp，
            // 「沙海 · 沙丘脊线，平行而长」已经贴到省略号，再加两个字就全被截掉。
            Row() {
              Column({ space: 2 }) {
                Text('背景主题')
                  .fontSize(16)
                  .fontColor($r('app.color.text_primary'))
                Text(this.backdrop().label + ' · ' + this.backdrop().hint)
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .alignItems(HorizontalAlign.Start)
              // 五个点占 5×34 + 4×6 = 194 vp，剩下给文字。不加 layoutWeight 时
              // 文字列会把自己的自然宽度全占掉，把圆点挤出卡片右边界。
              .layoutWeight(1)

              Row({ space: 6 }) {
                ForEach(ContourThemes.all, (item: ContourTheme, index: number) => {
                  this.BackdropSwatch(item, index)
                }, (item: ContourTheme) => item.key)
              }
            }
            .width('100%')

            // 卡片圆角那一行滑块已移除。它只影响「卡片有多圆」，既不是密度也不是
            // 可读性；而它存在时，卡片的弧度是一台机器一个值，筛选条 / 排序条那条
            // 胶囊却始终 17 vp——两种控件永远对不齐。现在圆角是常量 `CARD_CORNER`，
            // 卡片、设置分组卡片、搜索提示条与胶囊外壳共用同一个数。
          }
          .width('100%')
          .padding(14)
          .background(this.SettingsCardSurface(), CARD_BG_OPTIONS)
          .backgroundColor(Color.Transparent)
          .borderRadius(this.cardCorner)
        }

        ListItem() {
          this.SectionLabel('AI')
        }

        ListItem() {
          // AI 是**一个主题**：endpoint、密钥与三个场景的模型必须一起配好才有
          // 意义（缺 endpoint 时整组都跑不通），所以它们同处一张卡片，
          // 而不是拆成五行各自为政的开关。
          Column({ space: 12 }) {
            Row() {
              Column({ space: 2 }) {
                Text('AI 服务')
                  .fontSize(16)
                  .fontColor($r('app.color.text_primary'))
                Text('OpenAI 兼容接口 · 密钥存于系统密钥库')
                  .fontSize(11)
                  .fontColor($r('app.color.text_secondary'))
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              Text(this.aiKeyPresent ? '已保存密钥' : '未保存密钥')
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
            }
            .width('100%')

            this.AiField('接口地址', 'https://api.example.com/v1', 0)
            this.AiField('API 密钥', '可留空（本机 / 内网节点）', 4)
            this.AiField('洞见与格式', '模型名，例如 gpt-4o', 1)
            this.AiField('翻译', '模型名，例如 gpt-4o-mini', 2)
            this.AiField('润色', '模型名，例如 gpt-4o', 3)

            Row() {
              Text('凭据只写入系统密钥库，不随笔记同步，也不会出现在导出里。')
                .fontSize(11)
                .fontColor($r('app.color.text_secondary'))
                .layoutWeight(1)
              // 密钥存了就必须能删。没有这条，「换成一个不需要密钥的本机节点」
              // 会让旧 key 一直跟着发出去——服务端要么忽略、要么直接 401，
              // 而用户手上没有任何地方可以撤销它。
              if (this.aiKeyPresent) {
                Text('清除密钥')
                  .fontSize(12)
                  .fontColor($r('app.color.danger'))
                  .padding({ left: 10, right: 6, top: 6, bottom: 6 })
                  .onClick(() => {
                    this.clearAiKey();
                  })
                  .accessibilityText('清除已保存的 AI 密钥')
              }
              Text('保存')
                .fontSize(14)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.accentColor())
                .padding({ left: 12, right: 4, top: 6, bottom: 6 })
                .onClick(() => {
                  this.saveAiSettings();
                })
                .accessibilityText('保存 AI 设置')
            }
            .width('100%')
          }
          .width('100%')
          .padding(14)
          .background(this.SettingsCardSurface(), CARD_BG_OPTIONS)
          .backgroundColor(Color.Transparent)
          .borderRadius(this.cardCorner)
        }

        ListItem() {
          this.SectionLabel('同步与备份')
        }

        ListItem() {
          // 同步与备份是一个主题，三项合成**一张卡片**——与其它分组一致，
          // 免得页面上出现三张互不相干的单行卡片。
          //
          // 导入与导出是**两个同级配置项**，不是一个「导入 / 导出」再加一层
          // 动作表：那个动作表是系统样式的底部弹窗，与这一页的卡片语言毫无关系，
          // 而且一次点击只为了选两件事之一，等于多花一屏去问「你要哪个」。
          Column({ space: 14 }) {
            // `@Builder` 的调用返回 void，不能直接链 `.onClick`——所以外面再包一层
            // Row 来承接点击。行本身负责外观，包装只负责命中。
            Row() {
              this.WebDavRow(false)
            }
              .width('100%')
              .onClick(() => {
                this.openWebDav();
              })
            Row() {
              this.SettingRow('导出为 ZIP', '打包全部笔记与附件', '', false)
            }
              .width('100%')
              .onClick(() => {
                this.exportZip();
              })
            Row() {
              this.SettingRow('导入 Markdown / ZIP', '同名笔记会新增一份', '', false)
            }
              .width('100%')
              .onClick(() => {
                this.importNotes();
              })
          }
          .width('100%')
          .padding(14)
          .background(this.SettingsCardSurface(), CARD_BG_OPTIONS)
          .backgroundColor(Color.Transparent)
          .borderRadius(this.cardCorner)
        }

        ListItem() {
          this.SectionLabel('回收站')
        }

        ListItem() {
          this.SettingRow('回收站', '删除的笔记保留 30 天', '')
        }
        .onClick(() => {
          this.pathStack.pushPath({ name: 'trash' });
        })
        .background(this.SettingsCardSurface(), CARD_BG_OPTIONS)
        .backgroundColor(Color.Transparent)
        .borderRadius(this.cardCorner)

        ListItem() {
          this.SectionLabel('关于')
        }

        ListItem() {
          this.SettingRow('关于 纸见', 'API 26 · 本地优先', '')
        }
        .background(this.SettingsCardSurface(), CARD_BG_OPTIONS)
        .backgroundColor(Color.Transparent)
        .borderRadius(this.cardCorner)
      }
      .width('100%')
      .layoutWeight(1)
      .contentEndOffset(120)
      .padding({ left: this.SIDE_INSET, right: this.SIDE_INSET })
      // 与笔记网格同一套让位判定：上滑收起顶栏与页签栏，回到顶部再请回来。
      // 设置页没有筛选带，`hideTitleBar` 收的只是标题行本身，但「让位」这件事
      // 三个页签必须是同一种手感——在设置页上滑而什么都不动，会让人以为卡住了。
      .onDidScroll(() => {
        this.handleChromeScroll(this.settingsScroller);
      })
      // 收起后这一页的上边界同样落在状态栏下沿，第一张分组卡片会被裁成一条直线。
      // 与笔记网格用同一条渐隐，两个页签的「被让出来的边界」才是同一种语言。
      .fadingEdge(true, { fadingEdgeLength: LengthMetrics.vp(CHROME_FADE) })
    }
    .width('100%')
    .height('100%')
    // Same band reserve as the other tabs: the HDS title bar owns the 大标题. 设置页
    // 没有筛选条那一带，`bandInset` 最终会收到 0，所以这里就是状态栏 + 标题行
    // 的高度——但它是**走过去的**，不是一帧跳过去的。
    //
    // 顶栏收起时这里必须跟着让位（`pageTopInset()` 的另一半），否则标题栏走了、
    // 内容还留着 145 vp 的空带，屏幕上就是「上面秃了一块」而不是「让出来了」。
    .padding({ top: this.pageTopInset() })
  }

  /**
   * 一个背景主题的色点。
   *
   * 三层，从外到内：选中环、底色圆、强调色圆点。**中间的强调色圆点是重点**——
   * 底色五个都很接近（都是近白 / 近黑带一点色偏），只画底色五个点看上去几乎
   * 一样；而「选这一项会得到什么颜色的按钮」才是用户真正在比较的东西。
   *
   * 选中环也用该主题的强调色（不是线色）：它和圆点同色，一眼就能看出「这一圈
   * 亮起来的那套色相，就是它给你的强调色」。
   *
   * 尺寸 34 vp：这一行有五个点，44 vp 会把左侧标题列挤掉一半（五个点
   * 5×34 + 4×6 = 194 vp）。
   */
  @Builder
  BackdropSwatch(item: ContourTheme, index: number) {
    Column({ space: 4 }) {
      Stack({ alignContent: Alignment.Center }) {
        if (this.backdropTheme === index) {
          Circle()
            .width(34)
            .height(34)
            .fillOpacity(0)
            .stroke(this.accentOf(item))
            .strokeWidth(1.5)
        }
        Circle()
          .width(this.backdropTheme === index ? 28 : 24)
          .height(this.backdropTheme === index ? 28 : 24)
          .fill(item.mid(this.activeDark()))
        Circle()
          .width(this.backdropTheme === index ? 12 : 10)
          .height(this.backdropTheme === index ? 12 : 10)
          .fill(this.accentOf(item))
      }
      .width(34)
      .height(34)
      Text(item.label)
        .fontSize(10)
        .fontColor(this.backdropTheme === index ? this.accentColor() : $r('app.color.text_secondary'))
    }
    .width(34)
    .accessibilityText(`背景主题${item.label}`)
    .onClick(() => {
      this.setBackdropTheme(index);
    })
  }

  /**
   * One segment of a 分段控件 (theme mode / glass gear).
   * `kind` selects which setting the segment writes: `SEG_THEME` or `SEG_GLASS`.
   * It is a numeric discriminant rather than a set of booleans because two
   * mutually-exclusive rows would otherwise need two flags and a precedence rule.
   */
  @Builder
  SegmentButton(label: string, value: number, kind: number = SEG_THEME) {
    Text(label)
      .fontSize(12)
      .fontWeight(FontWeight.Medium)
      // 不用 onAccentColor()：分段控件改用 chip 语言（浅底 + 强调色字），
      // 与筛选条、标签页的选中态保持一致，避免同一应用里出现两种「选中」视觉。
      .fontColor(this.segmentSelected(value, kind) ? this.accentColor() : $r('app.color.text_secondary'))
      .padding({ left: 10, right: 10, top: 6, bottom: 6 })
      // 11 而非 14：外层胶囊已有 borderRadius(14) 且内边距仅 3 vp，
      // 子节点若也 14，圆角弧会顶到父边界，产生裁切白边。
      .borderRadius(11)
      // 浅底强调色字，与 ChipIndicator 同语言；不用实心强调色，
      // 避免三个分段按钮看起来像一排实心胶囊，与筛选条风格割裂。
      .backgroundColor(this.segmentSelected(value, kind) ? this.accentChipColor() : Color.Transparent)
      // 200 ms FastOutSlowIn 与 ChipIndicator / FilterChip 对齐，
      // 使所有选中态滑块/底色切换共享同一套时序，减少界面各处动画节奏差异。
      .animation({ duration: 200, curve: Curve.FastOutSlowIn })
      .onClick(() => {
        if (kind === SEG_GLASS) {
          // Repaints every glass surface immediately; the effect tables read
          // `glassLevel` directly, so no rebuild is required.
          this.setGlassLevel(value);
        } else if (kind === SEG_EDIT) {
          // 0 = 简单（整篇输入），1 = 分块。
          this.setSimpleEditing(value === 0);
        } else {
          this.setThemeMode(value);
        }
      })
  }

  private segmentSelected(value: number, kind: number): boolean {
    if (kind === SEG_GLASS) {
      return this.glassLevel === value;
    }
    if (kind === SEG_EDIT) {
      return (value === 0) === this.simpleEditing;
    }
    return this.themeMode === value;
  }

  @Builder
  SectionLabel(title: string) {
    Text(title)
      .fontSize(12)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.text_secondary'))
      .width('100%')
      .padding({ left: 4, top: 6, bottom: 0 })
  }

  /**
   * 设置页的分组卡片表面。
   *
   * 与笔记卡片是**同一种东西**：同一个 `CardSurface`、同一个卡片圆角设置、同一层
   * 沉浸光感与同一道落在背景上的阴影。设置页原来用的是一块平涂的半透明底色加
   * 写死的 20 vp 圆角，看起来像另一个应用里的控件。
   */
  @Builder
  SettingsCardSurface() {
    CardSurface({
      radius: this.cardCorner,
      glassOn: this.glassOn(),
      glassGear: this.glassLevel,
      glassTint: this.glassTint()
    })
  }

  /**
   * 一行 AI 配置：左侧标签，右侧输入框。
   *
   * `field` 是数字而不是字符串键，因为 ArkTS 不允许索引签名——`drafts[field]`
   * 这种写法编译不过，而三处开关 + 一个 endpoint 写四遍 `if` 又会分叉。
   *
   * 值**在构建体内部读**（`this.aiFieldValue(field)`），不通过参数传进来：`@Builder`
   * 的参数是按值比较的，传进来的字符串一旦没变，框架就跳过这棵子树——这条在
   * 设置页 WebDAV 行上已经踩过一次（见 `WebDavRow`）。
   */
  @Builder
  AiField(label: string, hint: string, field: number) {
    Row({ space: 10 }) {
      Text(label)
        .fontSize(13)
        .fontColor($r('app.color.text_primary'))
        .width(84)
        .maxLines(1)
      TextInput({
        text: this.aiFieldValue(field),
        placeholder: field === 4 && this.aiKeyPresent ? '已保存，留空则不修改' : hint
      })
        .layoutWeight(1)
        .height(38)
        .type(field === 4 ? InputType.Password : InputType.Normal)
        .backgroundColor($r('app.color.page_bg'))
        .borderRadius(10)
        .padding({ left: 10, right: 10 })
        .fontSize(13)
        .fontColor($r('app.color.text_primary'))
        .placeholderColor($r('app.color.text_secondary'))
        .caretColor(this.accentColor())
        .onChange((value: string) => {
          this.setAiField(field, value);
        })
    }
    .width('100%')
  }

  /**
   * 清掉已保存的密钥。
   *
   * 存在的理由：本机 / 内网节点不需要鉴权，而一个存过的 key 会跟着每个请求发
   * 出去。没有这条，「把 endpoint 换成本机节点」这件事就做不干净——用户手上
   * 没有任何地方能撤销那把旧 key。
   */
  private clearAiKey(): void {
    AiKey.remove().then(() => {
      this.aiKeyPresent = false;
      this.aiKeyDraft = '';
      Toast.show(this.getUIContext(), '密钥已清除');
    });
  }

  private aiFieldValue(field: number): string {
    if (field === 0) {
      return this.aiEndpointDraft;
    }
    if (field === 4) {
      return this.aiKeyDraft;
    }
    if (field === 1) {
      return this.aiModelDraft0;
    }
    if (field === 2) {
      return this.aiModelDraft1;
    }
    return this.aiModelDraft2;
  }

  private setAiField(field: number, value: string): void {
    if (field === 0) {
      this.aiEndpointDraft = value;
      return;
    }
    if (field === 4) {
      this.aiKeyDraft = value;
      return;
    }
    if (field === 1) {
      this.aiModelDraft0 = value;
      return;
    }
    if (field === 2) {
      this.aiModelDraft1 = value;
      return;
    }
    this.aiModelDraft2 = value;
  }

  /**
   * 保存 AI 设置。
   *
   * endpoint 与模型名进 `preferences`（不是秘密），密钥进 Asset Store。密钥输入框
   * **永远不回填**：留空表示「不修改已经存好的那一把」，与 WebDAV 密码同一套约定
   * ——一个每次打开设置页都要重新输入的密钥，用户只会把它写在便签上。
   */
  private saveAiSettings(): void {
    const settings = SettingsStore.instance;
    settings.setAiEndpoint(this.aiEndpointDraft.trim());
    settings.setAiModel(0, this.aiModelDraft0.trim());
    settings.setAiModel(1, this.aiModelDraft1.trim());
    settings.setAiModel(2, this.aiModelDraft2.trim());

    const key: string = this.aiKeyDraft.trim();
    if (key.length === 0) {
      Toast.show(this.getUIContext(), 'AI 设置已保存');
      return;
    }
    AiKey.save(key).then((ok: boolean) => {
      if (ok) {
        // 草稿里不留明文：保存成功之后这个输入框的价值已经用完了。
        this.aiKeyDraft = '';
        this.aiKeyPresent = true;
      }
      Toast.show(this.getUIContext(), ok ? 'AI 设置已保存' : '密钥保存失败');
    });
  }

  @Builder
  SettingRow(title: string, value: string, subtitle: string, padded: boolean = true) {
    Row() {
      Column({ space: 2 }) {
        Text(title)
          .fontSize(16)
          .fontColor($r('app.color.text_primary'))
        if (subtitle.length > 0) {
          Text(subtitle)
            .fontSize(11)
            .fontColor($r('app.color.text_secondary'))
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text(value)
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .margin({ left: 8 })
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(16)
        .fontColor([$r('app.color.text_secondary')])
        .margin({ left: 4 })
    }
    .width('100%')
    .padding(padded ? 14 : 0)
  }

  /**
   * The 设置 › WebDAV 同步 row.
   *
   * Deliberately **not** `SettingRow('WebDAV 同步', this.davRowValue(), ...)`.
   * A `@Builder`'s parameters are passed by value: the framework compares them
   * and skips the subtree when they are unchanged, so a `@Local` read *inside the
   * argument expression* is not a dependency of the built nodes. Measured on the
   * device: `didShow` fired and `davLastSync` advanced to the new timestamp, yet
   * the row kept rendering the pre-sync text. Reading the state directly in a
   * parameter-less builder is what makes it re-render.
   */
  @Builder
  WebDavRow(padded: boolean = true) {
    Row() {
      Column({ space: 2 }) {
        Text('WebDAV 同步')
          .fontSize(16)
          .fontColor($r('app.color.text_primary'))
        if (this.davLastSync > 0) {
          Text(`上次同步 · ${Index.formatSyncTime(this.davLastSync)}`)
            .fontSize(11)
            .fontColor($r('app.color.text_secondary'))
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text(this.davStateLabel)
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .margin({ left: 8 })
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(16)
        .fontColor([$r('app.color.text_secondary')])
        .margin({ left: 4 })
    }
    .width('100%')
    .padding(padded ? 14 : 0)
  }

  /** Recomputes the 设置 › WebDAV 同步 row from the settings singleton. */
  private refreshDavState(): void {
    const settings = SettingsStore.instance;
    this.davLastSync = settings.syncFinishedAt;
    if (settings.davUrl.length === 0) {
      this.davStateLabel = '未配置';
      return;
    }
    if (settings.syncFinishedAt > 0) {
      this.davStateLabel = '已同步';
      return;
    }
    this.davStateLabel = settings.davUser.length > 0 ? '待同步' : '未完成';
  }

  private static formatSyncTime(at: number): string {
    const now = systemDateTime.getTime();
    const diff = now - at;
    const minute = 60_000;
    const hour = 3_600_000;
    const day = 86_400_000;
    if (diff < minute) {
      return '刚刚';
    }
    if (diff < hour) {
      return `${Math.floor(diff / minute)} 分钟前`;
    }
    if (diff < day) {
      return `${Math.floor(diff / hour)} 小时前`;
    }
    if (diff < day * 2) {
      return '昨天';
    }
    const date = new Date(at);
    const month = (date.getMonth() + 1).toString().padStart(2, '0');
    const dayNum = date.getDate().toString().padStart(2, '0');
    const hh = date.getHours().toString().padStart(2, '0');
    const mm = date.getMinutes().toString().padStart(2, '0');
    return `${month}-${dayNum} ${hh}:${mm}`;
  }

  private openWebDav(): void {
    this.pathStack.pushPath({ name: 'webdav' });
  }

  /**
   * 导入 / 导出是**两个同级配置项**（`同步与备份` 卡片里的两行），不再是
   * 「导入 / 导出」+ 一层系统动作表。
   *
   * 系统动作表（`showActionSheet`）是白底、系统字体、一排蓝色文字的底部弹窗，
   * 与这一页的卡片、材质、强调色毫无关系；为「二选一」专门占掉一屏，也不值得。
   */
  private exportZip(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    NoteTransfer.exportZip(context).then((result: TransferResult) => {
      Toast.show(this.getUIContext(), result.message);
    });
  }

  private importNotes(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    NoteTransfer.importFiles(context).then((result: TransferResult) => {
      this.store.reload();
      this.refreshList();
      Toast.show(this.getUIContext(), result.message);
    });
  }
}
