import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { display, LengthMetrics, uiMaterial } from '@kit.ArkUI';
import { deviceInfo, BusinessError, systemDateTime } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { WindowService } from '../common/WindowService';
import { SettingsStore } from '../services/SettingsStore';
import { Note } from '../models/Note';
import { NoteStore } from '../services/NoteStore';
import { NoteCard } from '../components/NoteCard';
import { MaterialLayer } from '../components/MaterialLayer';
import { EditorPage } from './EditorPage';
import { TrashPage } from './TrashPage';
import { ReaderPage, ReaderParam } from './ReaderPage';
import { WebDavPage } from './WebDavPage';
import { NoteTransfer, TransferResult } from '../services/NoteTransfer';
import { Credentials } from '../services/Credentials';
import { SyncEngine } from '../services/SyncEngine';
import { AccentScheme, Palette } from '../common/Palette';
import { FONT_SIZE_MAX, FONT_SIZE_MIN, CARD_RADIUS_MAX, CARD_RADIUS_MIN, CARD_RADIUS_DEFAULT,
  GEAR_ADAPTIVE, GEAR_HIGH, GEAR_LOW, GEAR_MEDIUM,
  GLASS_LEVEL_DEFAULT, GLASS_LEVEL_MAX, GLASS_LEVEL_MIN,
  LINE_HEIGHT_MAX, LINE_HEIGHT_MIN } from '../services/SettingsStore';
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
  HdsAnimationMode
} from '@kit.UIDesignKit';

/**
 * HDS (`@kit.UIDesignKit`) requires 6.1.0 / API 23 for the floating tab bar and
 * immersive material. Below that the shell falls back to a plain pinned `Tabs`
 * with a hand-drawn bar, so the app must never touch the HDS path unguarded.
 */
const HDS_MIN_API: number = 23;

/** Stable id for the notes search field so the title-bar action can focus it. */
const SEARCH_INPUT_ID: string = 'notesSearchInput';

const DOMAIN: number = 0x0000;
const TAG: string = 'HMStart';

/**
 * Which setting a `SegmentButton` writes. Numeric discriminants (not booleans)
 * because the settings page has three independent segmented rows and a boolean
 * pair would need a precedence rule.
 */
const SEG_THEME: number = 0;
const SEG_GLASS: number = 1;

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
  @Local listVersion: number = 0;
  @Local notesSnapshot: Note[] = [];
  @Local themeMode: number = 0;
  @Local accentMode: number = 0;
  @Local fontSize: number = 17;
  @Local lineHeight: number = 175;
  /**
   * Immersive glass strength gear (0 restrained / 1 reference / 2 deepest).
   * Persisted by `SettingsStore` and read through the gear tables below, so the
   * whole UI changes depth together instead of each surface drifting.
   */
  @Local glassLevel: number = GLASS_LEVEL_DEFAULT;
  /** Note-card corner radius in vp; mirrors `SettingsStore.cardRadius`. */
  @Local cardRadius: number = CARD_RADIUS_DEFAULT;
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

  aboutToAppear(): void {
    this.themeMode = SettingsStore.instance.themeMode;
    this.accentMode = SettingsStore.instance.accentMode;
    this.fontSize = SettingsStore.instance.editorFontSize;
    this.lineHeight = SettingsStore.instance.editorLineHeight;
    this.glassLevel = SettingsStore.instance.glassLevel;
    this.cardRadius = SettingsStore.instance.cardRadius;
    this.refreshDavState();

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
    this.listVersion++;
  }

  private visibleNotes(): Note[] {
    const q = this.query.trim().toLowerCase();
    const scored: Note[] = [];
    for (const note of this.notesSnapshot) {
      if (this.filterMode === 1 && !note.pinned) {
        continue;
      }
      if (this.filterMode === 2 && !note.favorite) {
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

  private applySort(list: Note[]): void {
    if (this.sortMode === 1) {
      list.sort((a: Note, b: Note): number => a.title.localeCompare(b.title, 'zh-CN'));
      return;
    }
    if (this.sortMode === 2) {
      list.sort((a: Note, b: Note): number => b.createdAt - a.createdAt);
      return;
    }
    // Default: pinned first, then most recently edited.
    list.sort((a: Note, b: Note): number => {
      if (a.pinned !== b.pinned) {
        return a.pinned ? -1 : 1;
      }
      return b.updatedAt - a.updatedAt;
    });
  }

  private matches(note: Note, q: string): boolean {
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
        if (operation !== NavigationOperation.POP) {
          return;
        }
        this.store.reload();
        this.refreshList();
        this.refreshDavState();
      }
    });
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

  private setAccentMode(mode: number): void {
    this.accentMode = mode;
    SettingsStore.instance.setAccentMode(mode);
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

  private scheme(): AccentScheme {
    return Palette.scheme(this.accentMode);
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

  private accentGlowColor(): string {
    return this.scheme().glow(this.activeDark());
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
    } else if (name === 'editor') {
      EditorPage({
        pathStack: this.pathStack,
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
        accentColor: this.accentColor()
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

  private switchTab(index: number): void {
    if (index === this.selectedTab) {
      return;
    }
    this.selectedTab = index;
    // The title row is shared by all tabs; leaving search expanded while the
    // notes list is off-screen would hide the title of the new tab.
    this.searchExpanded = false;
    this.hdsTabs.changeIndex(index);
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
    this.searchExpanded = true;
    if (this.selectedTab !== 0) {
      this.selectedTab = 0;
      this.hdsTabs.changeIndex(0);
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
    const content: TitleBarContentOptions = {
      stackBuilder: () => {
        this.TitleRow();
      }
    };
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

      // Search and new-note are notes-tab actions; the other tabs show the
      // bare title row.
      if (this.selectedTab === 0 && !this.searchExpanded) {
        this.CircleAction($r('sys.symbol.magnifyingglass'), () => {
          this.searchExpanded = true;
          setTimeout(() => {
            this.getUIContext().getFocusController().requestFocus(SEARCH_INPUT_ID);
          }, 80);
        }, '搜索')
      }

      if (this.selectedTab === 0) {
        this.CircleAction($r('sys.symbol.plus'), () => {
          this.newNote();
        }, '新建笔记')
      }
    }
    .width('100%')
    .height(56)
    .padding({ left: this.SIDE_INSET, right: this.SIDE_INSET })
    .alignItems(VerticalAlign.Center)
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
      .systemMaterial(this.immersiveMaterial())
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
  private immersiveMaterial(): uiMaterial.ImmersiveMaterial {
    const styles: uiMaterial.ImmersiveStyle[] = [
      uiMaterial.ImmersiveStyle.REGULAR,     // 自适应 — 官方默认
      uiMaterial.ImmersiveStyle.ULTRA_THICK, // 高
      uiMaterial.ImmersiveStyle.REGULAR,     // 中
      uiMaterial.ImmersiveStyle.THIN         // 低
    ];
    const light: uiMaterial.LightEffectOptions = { color: this.accentColor() };
    const options: uiMaterial.ImmersiveOptions = {
      style: styles[this.glassIndex()],
      interactive: true,
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
      .barFloatingStyle(this.floatingBarStyle())
      .onChange((index: number) => {
        this.selectedTab = index;
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
    .bindToScrollable([this.notesScroller])
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
    .onChange((index: number) => {
      this.selectedTab = index;
    })
    .width('100%')
    .height('100%')
  }

  // ------------------------------------------------------------- backdrop

  /**
   * The single page backdrop. 光感 is the only style: an accent-tinted wash plus
   * four accent-coloured glow orbs.
   *
   * The 纯色 and 渐变 options were removed by product decision — with only three
   * accent hues and one shape language, three background styles produced nine
   * subtly different canvases where nobody could tell which was "the design".
   * One style that follows 强调色 gives the user a real choice (three clearly
   * distinct moods) instead of a fake one.
   *
   * Every colour here comes from `Palette`, not from `$r('app.color.page_grad_*')`.
   * That is load-bearing: ArkUI resolves resources once at build time, so a
   * resource cannot follow a runtime accent switch — the same reason
   * `accentColor()` is a hex string. The resource entries are kept only so the
   * dark-mode table stays complete and older builds do not resolve undefined.
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
            [this.scheme().pageTop(this.activeDark()), 0.0],
            [this.scheme().pageMid(this.activeDark()), 0.55],
            [this.scheme().pageBottom(this.activeDark()), 1.0]
          ]
        })
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      // The four orbs are the accent's own glow at four sizes. Previously three
      // of them were fixed blue/purple/cyan, so a teal UI sat on a blue-plus-
      // violet sky — the complaint that the backdrop ignored 强调色.
      Column()
        .width(560)
        .height(560)
        .borderRadius(280)
        .radialGradient({
          center: ['50%', '50%'],
          radius: 280,
          colors: [[this.accentGlowColor(), 0.0], ['#00000000', 1.0]]
        })
        .opacity(0.9)
        .position({ x: -220, y: -200 })
      Column()
        .width(380)
        .height(380)
        .borderRadius(190)
        .radialGradient({
          center: ['50%', '50%'],
          radius: 190,
          colors: [[this.accentGlowColor(), 0.0], ['#00000000', 1.0]]
        })
        .opacity(0.55)
        .position({ x: 860, y: 180 })
      Column()
        .width(520)
        .height(520)
        .borderRadius(260)
        .radialGradient({
          center: ['50%', '50%'],
          radius: 260,
          colors: [[this.accentGlowColor(), 0.0], ['#00000000', 1.0]]
        })
        .opacity(0.8)
        .position({ x: 360, y: 1680 })
      Column()
        .width(380)
        .height(380)
        .borderRadius(190)
        .radialGradient({
          center: ['50%', '50%'],
          radius: 190,
          colors: [[this.accentGlowColor(), 0.0], ['#00000000', 1.0]]
        })
        .opacity(0.5)
        .position({ x: 900, y: 1760 })
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None)
  }

  // ---------------------------------------------------------------- notes

  /**
   * Clearance for the title bar band. HDS draws `NavBarContent` at the same
   * origin as the title bar, so each tab root must reserve that band itself.
   *
   * Measured on device in MINI mode with `.hideBackButton(true)`:
   * `HdsTitleBar` spans y 0…285 px at density 3, i.e. 95 vp from the window
   * origin (immersion is done with `ignoreLayoutSafeArea`, so the content
   * origin is the window top, not below the status bar). 96 vp clears it with a
   * 1 vp hairline of slack; anything less pushes the filter row up into the
   * title bar.
   */
  private readonly TITLE_BAR_CLEARANCE: number = 96;

  /**
   * Width of one grid column in vp. `WaterFlow` measures a `FlowItem`'s child
   * against the whole flow, so a card must be given an explicit column width or
   * wide content bleeds across into the next column.
   */
  private columnWidth(): number {
    const widthPx = display.getDefaultDisplaySync().width;
    const density = display.getDefaultDisplaySync().densityPixels;
    const widthVp = widthPx / density;
    return (widthVp - this.SIDE_INSET * 2 - 12) / 2;
  }

  @Builder
  NotesPage() {
    Column() {
      this.NotesHeader()

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
                  pinned: note.pinned,
                  favorite: note.favorite,
                  updatedAt: note.updatedAt,
                  accentColor: this.accentColor(),
                  accentChipColor: this.accentChipColor(),
                  cornerRadius: this.cardRadius,
                  glassOn: this.glassOn(),
                  glassGear: this.glassLevel,
                  glassTint: this.glassTint(),
                  onOpen: (id: string) => {
                    const target = this.store.find(id);
                    if (target !== undefined) {
                      this.openNote(target);
                    }
                  },
                  onTogglePin: (id: string) => {
                    const target = this.store.find(id);
                    if (target !== undefined) {
                      this.store.togglePin(target);
                      this.refreshList();
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
                  }
                })
              }
              .width(this.columnWidth())
            }
          }, (note: Note) => `${note.id}-${note.updatedAt}`)
        }
        .columnsTemplate('1fr 1fr')
        .columnsGap(12)
        .rowsGap(12)
        .padding({ left: this.SIDE_INSET, right: this.SIDE_INSET })
        .width('100%')
        .layoutWeight(1)
        // Clears the floating capsule so the last row stays reachable.
        .contentEndOffset(130)
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
          .fontSize(14)
          .backgroundColor(this.accentColor())
          .fontColor(this.onAccentColor())
          .borderRadius(12)
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

  @Builder
  NotesHeader() {
    // No search field here: search lives in the title row and expands in place.
    // The single filter row is the only pinned chrome above the grid, so the
    // header is now one compact band instead of three stacked rows.
    Row({ space: 8 }) {
      this.ChipGroup(0)
      this.ChipGroup(10)
    }
    .width('100%')
    // The measured title row band on this device; the smaller value than before
    // reflects the title row no longer reserving a separate large-title band.
    .padding({ left: this.SIDE_INSET, right: this.SIDE_INSET, top: this.TITLE_BAR_CLEARANCE, bottom: 10 })
  }

  /**
   * A single capsule holding one chip group. Two of these share one row:
   * filter (全部/置顶/收藏) on the left, sort (最近修改/按标题/按创建) on the
   * right. `base` 0 = filter, 10 = sort; `FilterChip` treats `mode >= 10` as
   * sort, so any future group must use a multiple of 10 as its base.
   *
   * The surface is a `MaterialLayer` carrier when the device renders immersive
   * material, and the hand-built `backgroundEffect` glass otherwise. It cannot be
   * `.systemMaterial()` on this `Stack`: page content is outside the material's
   * allowed scopes, so the call is a silent no-op — the reason this used a
   * hand-built blur in the first place.
   */
  @Builder
  ChipGroup(base: number) {
    Stack({ alignContent: Alignment.Center }) {
      if (this.glassOn()) {
        MaterialLayer({
          radius: 17,
          gear: this.glassLevel
        })
        Column()
          .width('100%')
          .height('100%')
          .borderRadius(17)
          .backgroundColor(this.glassTint())
      } else {
        Column()
          .width('100%')
          .height('100%')
          .backgroundEffect(this.glassEffect())
        Column()
          .width('100%')
          .height('100%')
          .linearGradient({
            angle: 180,
            colors: [[$r('app.color.glass_hi'), 0.0], ['#00FFFFFF', this.glassSheenStop()]]
          })
      }
      Row({ space: 2 }) {
        if (base === 0) {
          this.FilterChip('全部', 0)
          this.FilterChip('置顶', 1)
          this.FilterChip('收藏', 2)
        } else {
          this.FilterChip('最近修改', 10)
          this.FilterChip('按标题', 11)
          this.FilterChip('按创建', 12)
        }
      }
      .width('100%')
      .height('100%')
      .padding(3)
    }
    .layoutWeight(1)
    .height(34)
    .borderRadius(17)
    .clip(true)
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
          .onChange((value: string) => {
            this.query = value;
          })
        Button() {
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(16)
            .fontColor([$r('app.color.text_secondary')])
        }
        .width(28)
        .height(28)
        .borderRadius(14)
        .padding(0)
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          // Collapsing clears the query so the list returns to its full state.
          this.query = '';
          this.searchExpanded = false;
        })
        .accessibilityText('关闭搜索')
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
    .systemMaterial(this.immersiveSupported ? this.immersiveMaterial() : uiMaterial.Material.empty)
    .border(this.immersiveSupported
      ? { width: 0 }
      : { width: this.glassRimWidth(), color: $r('app.color.glass_border') })
    .backgroundEffect(this.immersiveSupported ? undefined : this.glassEffect())
  }

  /**
   * Two logical chip groups share one builder: `mode` < 10 is the filter row
   * (全部/置顶/收藏), `mode` >= 10 is the sort row. Selected state is a tinted
   * wash + accent text, never a saturated accent block: a solid accent fill
   * inside a glass pill reads as a heavy slab.
   */
  @Builder
  FilterChip(label: string, mode: number) {
    Text(label)
      .fontSize(12)
      .fontWeight(this.chipSelected(mode) ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.chipSelected(mode) ? this.accentColor() : $r('app.color.text_secondary'))
      .textAlign(TextAlign.Center)
      .layoutWeight(1)
      .height(28)
      .borderRadius(14)
      .backgroundColor(this.chipSelected(mode) ? this.accentChipColor() : Color.Transparent)
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .animation({ duration: 160, curve: Curve.EaseOut })
      .onClick(() => {
        if (mode < 10) {
          this.filterMode = mode;
        } else {
          this.sortMode = mode - 10;
        }
      })
      .accessibilityText(label)
  }

  private chipSelected(mode: number): boolean {
    return mode < 10 ? this.filterMode === mode : this.sortMode === mode - 10;
  }

  @Builder
  EmptyState() {
    Column({ space: 10 }) {
      SymbolGlyph($r('sys.symbol.doc_text'))
        .fontSize(48)
        .fontColor([$r('app.color.text_secondary')])
        .opacity(0.6)
      Text('还没有笔记')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
      Text('点击右上角 + 记录第一条')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .padding({ bottom: 120 })
  }


  // ----------------------------------------------------------------- tags

  @Builder
  TagsPage() {
    Column({ space: 12 }) {
      if (this.store.tags.length === 0) {
        Text('还没有标签。在笔记 frontmatter 里添加 tags 字段后会自动出现在这里。')
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .padding({ left: this.SIDE_INSET, right: this.SIDE_INSET })
      } else {
        List({ space: 8, scroller: this.tagsScroller }) {
          ForEach(this.store.tags, (tag: string) => {
            ListItem() {
              Row() {
                Text(`# ${tag}`)
                  .fontSize(16)
                  .fontColor($r('app.color.text_primary'))
                Blank()
                Text(`${this.store.countTag(tag)}`)
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
              }
              .width('100%')
              .padding(14)
              .borderRadius(16)
              .backgroundColor($r('app.color.glass_bg'))
              .onClick(() => {
                this.filterByTag(tag);
              })
            }
            .padding({ left: this.SIDE_INSET, right: this.SIDE_INSET })
          }, (tag: string) => tag)
        }
        .width('100%')
        .layoutWeight(1)
        .contentEndOffset(120)
      }
    }
    .width('100%')
    .height('100%')
    // No local heading: the HDS title bar owns the page title (大标题) on every
    // tab, so each tab only reserves that band.
    .padding({ top: this.TITLE_BAR_CLEARANCE })
  }

  // -------------------------------------------------------------- settings

  @Builder
  SettingsPage() {
    Column({ space: 12 }) {
      List({ space: 8, scroller: this.settingsScroller }) {
        ListItem() {
          this.WebDavRow()
        }
        .onClick(() => {
          this.openWebDav();
        })

        ListItem() {
          this.SettingRow('导入 / 导出', 'Markdown + ZIP', '')
        }
        .onClick(() => {
          this.showTransferSheet();
        })

        ListItem() {
          this.SettingRow('回收站', '删除的笔记保留 30 天', '')
        }
        .onClick(() => {
          this.pathStack.pushPath({ name: 'trash' });
        })

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

            Row() {
              Column({ space: 2 }) {
                Text('强调色')
                  .fontSize(16)
                  .fontColor($r('app.color.text_primary'))
                Text('按钮、标签、选中态')
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
              }
              .alignItems(HorizontalAlign.Start)

              Blank()

              Row({ space: 6 }) {
                ForEach(Palette.schemes, (item: AccentScheme, index: number) => {
                  this.AccentSwatch(item, index)
                }, (item: AccentScheme) => item.label)
              }
            }
            .width('100%')
          }
          .width('100%')
          .padding(14)
          .backgroundColor($r('app.color.glass_bg'))
          .borderRadius(20)
        }

        ListItem() {
          Column({ space: 6 }) {
            Row() {
              Column({ space: 2 }) {
                Text('编辑器字号')
                  .fontSize(16)
                  .fontColor($r('app.color.text_primary'))
                Text(`${this.fontSize} px`)
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
              }
              .alignItems(HorizontalAlign.Start)
              Blank()
            }
            .width('100%')
            Slider({
              value: this.fontSize,
              min: FONT_SIZE_MIN,
              max: FONT_SIZE_MAX,
              step: 1,
              style: SliderStyle.OutSet
            })
              .selectedColor(this.accentColor())
              .blockColor(this.accentColor())
              .trackColor($r('app.color.divider'))
              .width('100%')
              .onChange((value: number) => {
                this.fontSize = Math.round(value);
                SettingsStore.instance.setEditorFontSize(this.fontSize);
              })

            Row() {
              Column({ space: 2 }) {
                Text('行距')
                  .fontSize(16)
                  .fontColor($r('app.color.text_primary'))
                Text(`${(this.lineHeight / 100).toFixed(2)} 倍`)
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
              }
              .alignItems(HorizontalAlign.Start)
              Blank()
            }
            .width('100%')
            Slider({
              value: this.lineHeight,
              min: LINE_HEIGHT_MIN,
              max: LINE_HEIGHT_MAX,
              step: 5,
              style: SliderStyle.OutSet
            })
              .selectedColor(this.accentColor())
              .blockColor(this.accentColor())
              .trackColor($r('app.color.divider'))
              .width('100%')
              .onChange((value: number) => {
                this.lineHeight = Math.round(value);
                SettingsStore.instance.setEditorLineHeight(this.lineHeight);
              })

            Row() {
              Column({ space: 2 }) {
                Text('卡片圆角')
                  .fontSize(16)
                  .fontColor($r('app.color.text_primary'))
                Text(`${this.cardRadius} vp`)
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
              }
              .alignItems(HorizontalAlign.Start)
              Blank()
            }
            .width('100%')
            Slider({
              value: this.cardRadius,
              min: CARD_RADIUS_MIN,
              max: CARD_RADIUS_MAX,
              step: 2,
              style: SliderStyle.OutSet
            })
              .selectedColor(this.accentColor())
              .blockColor(this.accentColor())
              .trackColor($r('app.color.divider'))
              .width('100%')
              .onChange((value: number) => {
                this.cardRadius = Math.round(value);
                SettingsStore.instance.setCardRadius(this.cardRadius);
              })
          }
          .width('100%')
          .padding(14)
          .backgroundColor($r('app.color.glass_bg'))
          .borderRadius(20)
        }

        ListItem() {
          this.SettingRow('关于 纸见', 'API 26 · 本地优先', '')
        }
      }
      .width('100%')
      .layoutWeight(1)
      .contentEndOffset(120)
      .padding({ left: this.SIDE_INSET, right: this.SIDE_INSET })
    }
    .width('100%')
    .height('100%')
    // Same band reserve as the other tabs: the HDS title bar owns the 大标题.
    .padding({ top: this.TITLE_BAR_CLEARANCE })
  }

  @Builder
  AccentSwatch(item: AccentScheme, index: number) {
    Column({ space: 4 }) {
      Stack({ alignContent: Alignment.Center }) {
        Circle()
          .width(this.accentMode === index ? 30 : 24)
          .height(this.accentMode === index ? 30 : 24)
          .fill(item.accent(this.activeDark()))
        if (this.accentMode === index) {
          Circle()
            .width(38)
            .height(38)
            .fillOpacity(0)
            .stroke(item.accent(this.activeDark()))
            .strokeWidth(1.5)
        }
      }
      .width(38)
      .height(38)
      Text(item.label)
        .fontSize(10)
        .fontColor(this.accentMode === index ? item.accent(this.activeDark()) : $r('app.color.text_secondary'))
    }
    .width(44)
    .accessibilityText(`强调色${item.label}`)
    .onClick(() => {
      this.setAccentMode(index);
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
      .fontColor(this.segmentSelected(value, kind) ? this.onAccentColor() : $r('app.color.text_secondary'))
      .padding({ left: 10, right: 10, top: 6, bottom: 6 })
      .borderRadius(11)
      .backgroundColor(this.segmentSelected(value, kind) ? this.accentColor() : Color.Transparent)
      .animation({ duration: 160, curve: Curve.EaseOut })
      .onClick(() => {
        if (kind === SEG_GLASS) {
          // Repaints every glass surface immediately; the effect tables read
          // `glassLevel` directly, so no rebuild is required.
          this.setGlassLevel(value);
        } else {
          this.setThemeMode(value);
        }
      })
  }

  private segmentSelected(value: number, kind: number): boolean {
    if (kind === SEG_GLASS) {
      return this.glassLevel === value;
    }
    return this.themeMode === value;
  }

  @Builder
  SettingRow(title: string, value: string, subtitle: string) {
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
    .padding(14)
    .backgroundColor($r('app.color.glass_bg'))
    .borderRadius(20)
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
  WebDavRow() {
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
    .padding(14)
    .backgroundColor($r('app.color.glass_bg'))
    .borderRadius(20)
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

  private showTransferSheet(): void {
    const ui = this.getUIContext();
    ui.showActionSheet({
      title: '导入 / 导出',
      message: 'Markdown 与 ZIP（含附件）',
      autoCancel: true,
      confirm: {
        value: '取消',
        action: () => {}
      },
      sheets: [
        {
          title: '导出为 ZIP',
          action: () => {
            const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
            NoteTransfer.exportZip(context).then((result: TransferResult) => {
              this.getUIContext().getPromptAction().showToast({ message: result.message });
            });
          }
        },
        {
          title: '导入 Markdown / ZIP',
          action: () => {
            const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
            NoteTransfer.importFiles(context).then((result: TransferResult) => {
              this.store.reload();
              this.refreshList();
              this.getUIContext().getPromptAction().showToast({ message: result.message });
            });
          }
        }
      ]
    });
  }
}
