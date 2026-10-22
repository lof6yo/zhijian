import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { display, LengthMetrics, uiMaterial, CircleShape } from '@kit.ArkUI';
import { deviceInfo, BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { WindowService } from '../common/WindowService';
import { SettingsStore } from '../services/SettingsStore';
import { Note } from '../models/Note';
import { NoteStore } from '../services/NoteStore';
import { NoteCard } from '../components/NoteCard';
import { EditorPage } from './EditorPage';
import { TrashPage } from './TrashPage';
import { NoteTransfer, TransferResult } from '../services/NoteTransfer';
import { AccentScheme, Palette } from '../common/Palette';
import { FONT_SIZE_MAX, FONT_SIZE_MIN, GEAR_ADAPTIVE, GEAR_HIGH, GEAR_LOW, GEAR_MEDIUM,
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
const SEG_BACKGROUND: number = 1;
const SEG_GLASS: number = 2;

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
  @Local backgroundStyle: number = 2;
  @Local accentMode: number = 0;
  @Local fontSize: number = 17;
  @Local lineHeight: number = 175;
  /**
   * Immersive glass strength gear (0 restrained / 1 reference / 2 deepest).
   * Persisted by `SettingsStore` and read through the gear tables below, so the
   * whole UI changes depth together instead of each surface drifting.
   */
  @Local glassLevel: number = GLASS_LEVEL_DEFAULT;
  @Local pathStack: NavPathStack = new NavPathStack();
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
    this.backgroundStyle = SettingsStore.instance.backgroundStyle;
    this.accentMode = SettingsStore.instance.accentMode;
    this.fontSize = SettingsStore.instance.editorFontSize;
    this.lineHeight = SettingsStore.instance.editorLineHeight;
    this.glassLevel = SettingsStore.instance.glassLevel;

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

  private setBackgroundStyle(style: number): void {
    this.backgroundStyle = style;
    SettingsStore.instance.setBackgroundStyle(style);
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

  onPageShow(): void {
    if (this.store.ready) {
      this.store.reload();
      this.refreshList();
    }
  }

  // ------------------------------------------------------------ navigation

  @Builder
  pageMap(name: string) {
    if (name === 'editor') {
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
    }
  }

  private openNote(note: Note): void {
    this.pathStack.pushPath({
      name: 'editor',
      param: note.id
    });
  }

  /**
   * Creates a note and opens it.
   *
   * A mis-tap here would otherwise leave a stray 无标题 file behind, because
   * `createNote()` writes to disk immediately. The editor therefore receives
   * `createdAt` and, on return, discards the note if it was never touched —
   * see `EditorPage.discardIfUntouched()`. Creating eagerly (rather than
   * deferring the write until the first keystroke) is deliberate: the note must
   * exist for `EditorPage` to load it, and a note that *was* edited must survive
   * even if the user leaves within five seconds.
   */
  private newNote(): void {
    const note: Note = this.store.createNote();
    this.refreshList();
    this.pathStack.pushPath({
      name: 'editor',
      param: note.id
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
   * The circle comes from `clipShape(CircleShape)` rather than `borderRadius`,
   * matching the official sample; that is the outline the material is clipped to.
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
      .clipShape(new CircleShape({ width: 44, height: 44 }))
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
   */
  private immersiveMaterial(): uiMaterial.ImmersiveMaterial {
    const styles: uiMaterial.ImmersiveStyle[] = [
      uiMaterial.ImmersiveStyle.REGULAR,   // 自适应 — 官方默认
      uiMaterial.ImmersiveStyle.ULTRA_THICK, // 高
      uiMaterial.ImmersiveStyle.REGULAR,   // 中
      uiMaterial.ImmersiveStyle.THIN       // 低
    ];
    const options: uiMaterial.ImmersiveOptions = {
      style: styles[this.glassIndex()],
      interactive: true
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
    const width: HdsBarWidthRangeOptions = {
      smallWidth: 320,
      mediumWidth: 400,
      largeWidth: 460
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

  @Builder
  PageBackdrop() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.backgroundStyle === 0) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor($r('app.color.page_bg'))
          .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      } else {
        Column()
          .width('100%')
          .height('100%')
          .linearGradient({
            angle: 160,
            colors: [
              [$r('app.color.page_grad_top'), 0.0],
              [$r('app.color.page_grad_mid'), 0.55],
              [$r('app.color.page_grad_bottom'), 1.0]
            ]
          })
          .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      }

      if (this.backgroundStyle === 2) {
        Column()
          .width(560)
          .height(560)
          .borderRadius(280)
          .radialGradient({
            center: ['50%', '50%'],
            radius: 280,
            colors: [[$r('app.color.glow_blue'), 0.0], ['#00000000', 1.0]]
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
            colors: [[$r('app.color.glow_purple'), 0.0], ['#00000000', 1.0]]
          })
          .opacity(0.8)
          .position({ x: 860, y: 180 })
        Column()
          .width(520)
          .height(520)
          .borderRadius(260)
          .radialGradient({
            center: ['50%', '50%'],
            radius: 260,
            colors: [[$r('app.color.glow_cyan'), 0.0], ['#00000000', 1.0]]
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
            colors: [[$r('app.color.glow_purple'), 0.0], ['#00000000', 1.0]]
          })
          .opacity(0.75)
          .position({ x: 900, y: 1760 })
      }
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
   */
  @Builder
  ChipGroup(base: number) {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 180,
          colors: [[$r('app.color.glass_hi'), 0.0], ['#00FFFFFF', this.glassSheenStop()]]
        })
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
    .backgroundEffect(this.glassEffect())
    .border({ width: this.glassRimWidth(), color: $r('app.color.glass_border') })
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
    .clip(true)
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
          this.SettingRow('WebDAV 同步', '下一步接入')
        }
        .onClick(() => {
          this.showWebDavInfo();
        })

        ListItem() {
          this.SettingRow('导入 / 导出', 'Markdown + ZIP')
        }
        .onClick(() => {
          this.showTransferSheet();
        })

        ListItem() {
          this.SettingRow('回收站', '删除的笔记保留 30 天')
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
                Text('背景样式')
                  .fontSize(16)
                  .fontColor($r('app.color.text_primary'))
                Text('纯色 / 渐变 / 光感')
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
              }
              .alignItems(HorizontalAlign.Start)

              Blank()

              Row({ space: 2 }) {
                this.SegmentButton('纯色', 0, SEG_BACKGROUND)
                this.SegmentButton('渐变', 1, SEG_BACKGROUND)
                this.SegmentButton('光感', 2, SEG_BACKGROUND)
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
          }
          .width('100%')
          .padding(14)
          .backgroundColor($r('app.color.glass_bg'))
          .borderRadius(20)
        }

        ListItem() {
          this.SettingRow('关于 纸见', 'API 26 · 本地优先')
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
   * One segment of a 分段控件 (theme mode / background style / glass gear).
   * `kind` selects which setting the segment writes: `SEG_THEME`,
   * `SEG_BACKGROUND` or `SEG_GLASS`. It is a numeric discriminant rather than a
   * set of booleans because three mutually-exclusive rows would otherwise need
   * three flags and a precedence rule.
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
        if (kind === SEG_BACKGROUND) {
          this.setBackgroundStyle(value);
        } else if (kind === SEG_GLASS) {
          // Repaints every glass surface immediately; the effect tables read
          // `glassLevel` directly, so no rebuild is required.
          this.setGlassLevel(value);
        } else {
          this.setThemeMode(value);
        }
      })
  }

  private segmentSelected(value: number, kind: number): boolean {
    if (kind === SEG_BACKGROUND) {
      return this.backgroundStyle === value;
    }
    if (kind === SEG_GLASS) {
      return this.glassLevel === value;
    }
    return this.themeMode === value;
  }

  @Builder
  SettingRow(title: string, value: string) {
    Row() {
      Text(title)
        .fontSize(16)
        .fontColor($r('app.color.text_primary'))
      Blank()
      Text(value)
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
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

  private showWebDavInfo(): void {
    this.getUIContext().showAlertDialog({
      title: 'WebDAV 同步',
      message: '同步将在下一阶段接入：单账号、默认仅 Wi-Fi、冲突时保留副本。',
      confirm: {
        value: '知道了',
        action: () => {}
      }
    });
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
