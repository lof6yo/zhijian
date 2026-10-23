import { systemDateTime } from '@kit.BasicServicesKit';
import { CardSurface } from './CardSurface';

/**
 * `.background()` takes a typed options object: ArkTS rejects an inline object
 * literal (`arkts-no-untyped-obj-literals`), and the resulting parse failure
 * cascades into the rest of the attribute chain.
 */
const CARD_BG_OPTIONS: BackgroundOptions = { align: Alignment.Center };

/**
 * One 笔记卡片 in the grid.
 *
 * Takes **immutable primitive** props rather than a `Note`. `Note` is
 * `@ObservedV2`, so passing the object through `@Param` would leave the card
 * showing a pre-edit title until the whole grid happened to rebuild; the
 * `ForEach` key `${note.id}-${note.updatedAt}` plus primitive props is what
 * forces a fresh card when an existing note is edited.
 */
@ComponentV2
export struct NoteCard {
  @Param noteId: string = '';
  @Param title: string = '';
  @Param excerpt: string = '';
  @Param tags: string[] = [];
  @Param pinned: boolean = false;
  @Param favorite: boolean = false;
  @Param updatedAt: number = 0;
  /** Runtime accent from `Palette`; `$r('app.color.accent')` cannot follow the setting. */
  @Param accentColor: string = '#0A59F7';
  @Param accentChipColor: string = '#E8EEFF';
  /**
   * Card corner radius in vp, from 设置 › 卡片圆角.
   *
   * A `@Param` rather than a resource because the value is a runtime preference —
   * ArkUI resolves `$r('app.*')` at build time, so a user-selectable radius can
   * only travel as a number. The default matches `CARD_RADIUS_DEFAULT`; it is
   * repeated literally here so `NoteCard` does not import the settings store.
   */
  @Param cornerRadius: number = 26;
  /**
   * Whether the card paints the platform 沉浸光感 material behind its surface.
   *
   * Gated by the caller rather than probed here, because `uiMaterial` is API 26
   * and this component must keep working below it. When false the card falls
   * back to the opaque system card fill — never to transparent, which would make
   * the note disappear.
   */
  @Param glassOn: boolean = false;
  /** 沉浸光感挡位, 0 = 自适应 … 3 = 低. Fed to `MaterialLayer`. */
  @Param glassGear: number = 0;
  /**
   * A **translucent** veil painted *over* the material, giving the card its
   * surface colour.
   *
   * This is the difference between "glass card" and "no card". The material
   * refracts whatever is behind it, and this app's backdrop is a near-uniform
   * light accent wash — so on its own the material is almost invisible and the
   * grid loses all structure (verified on device: the first build with a bare
   * material carrier made every card the same tone as the page). A frosted veil
   * on top restores the surface while the material still supplies the edge
   * refraction.
   *
   * It must stay translucent: an opaque fill sits above the material's visual
   * layer and hides it completely.
   */
  @Param glassTint: string = '';
  @Event onOpen: (noteId: string) => void = () => {};
  @Event onTogglePin: (noteId: string) => void = () => {};
  @Event onToggleFavorite: (noteId: string) => void = () => {};
  @Event onDelete: (noteId: string) => void = () => {};
  @Event onEditTags: (noteId: string) => void = () => {};

  build() {
    Column({ space: 8 }) {
      Row({ space: 6 }) {
        Text(this.title.length > 0 ? this.title : '无标题')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        if (this.favorite) {
          Text('★')
            .fontSize(14)
            .fontColor($r('app.color.favorite'))
        }
        if (this.pinned) {
          Text('置顶')
            .fontSize(10)
            .fontColor(this.accentColor)
            .backgroundColor(this.accentChipColor)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .borderRadius(6)
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      if (this.excerpt.length > 0) {
        Text(this.excerpt)
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .lineHeight(19)
          .width('100%')
      }

      if (this.tags.length > 0) {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.tags.slice(0, 3), (tag: string) => {
            Text(tag)
              .fontSize(11)
              .fontColor($r('app.color.chip_text'))
              .backgroundColor($r('app.color.chip_bg'))
              .padding({ left: 7, right: 7, top: 3, bottom: 3 })
              .borderRadius(7)
              .margin({ right: 6, bottom: 4 })
          }, (tag: string) => tag)
        }
        .width('100%')
      }

      Text(this.relativeTime(this.updatedAt))
        .fontSize(11)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
    }
    .width('100%')
    .padding(16)
    .alignItems(HorizontalAlign.Start)
    // The surface is painted by `.background()`, in this order:
    //
    //   1. the material carrier (the Toggle that paints 沉浸光感), then
    //   2. a translucent veil, then
    //   3. the text above, as this Column's own children.
    //
    // Both choices are load-bearing.
    //
    // `.background(builder)` lays the carrier out against *this node's* already
    // measured box, so the material cannot inflate the card. Putting the carrier
    // in a `Stack` sibling instead did exactly that on device:
    // `LayoutPolicy.matchParent` resolved against the flow's available size and
    // every card grew to the full grid height — one row filled the screen.
    //
    // The veil has to sit above the material but below the text. Painting it as
    // `backgroundColor` would put it *below* the material, because the material's
    // visual layer is drawn above `backgroundColor`, and hide it entirely.
    .background(this.CardSurface(), CARD_BG_OPTIONS)
    // Transparent only when the carrier is actually painting. An opaque fallback
    // here would be correct-looking but would also cover the material.
    .backgroundColor(this.glassOn ? Color.Transparent : $r('sys.color.ohos_id_color_card_bg'))
    .borderRadius(this.cornerRadius)
    .shadow({ radius: 20, color: $r('app.color.glass_shadow'), offsetX: 0, offsetY: 6 })
    // Press feedback uses the platform interaction effect instead of
    // `.stateStyles()`: this toolchain rejects both the inline object literal
    // and `@Styles` function references as `StateStyles` values.
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.97 })
    .hoverEffect(HoverEffect.Auto)
    .onClick(() => {
      this.onOpen(this.noteId);
    })
    .bindContextMenu(this.CardMenu(), ResponseType.LongPress, {
      preview: MenuPreviewMode.NONE
    })
  }

  /**
   * Background layer: the shared card surface (沉浸光感 + 半透明遮罩).
   *
   * Settings 分组卡片用的是同一个 `CardSurface`——两处的圆角、材质强度与遮罩
   * 浓度必须一致，否则设置页看起来像另一个应用里的控件。
   */
  @Builder
  CardSurface() {
    CardSurface({
      radius: this.cornerRadius,
      glassOn: this.glassOn,
      glassGear: this.glassGear,
      glassTint: this.glassOn ? this.glassTint : ''
    })
  }

  @Builder
  CardMenu() {
    Menu() {
      MenuItem({ content: this.pinned ? '取消置顶' : '置顶' })
        .contentFontColor($r('app.color.text_primary'))
        .onClick(() => {
          this.onTogglePin(this.noteId);
        })
      MenuItem({ content: this.favorite ? '取消收藏' : '收藏' })
        .contentFontColor($r('app.color.text_primary'))
        .onClick(() => {
          this.onToggleFavorite(this.noteId);
        })
      MenuItem({ content: '标签…' })
        .contentFontColor($r('app.color.text_primary'))
        .onClick(() => {
          this.onEditTags(this.noteId);
        })
      MenuItem({ content: '删除' })
        .contentFontColor($r('app.color.danger'))
        .onClick(() => {
          this.confirmDelete();
        })
    }
  }

  /**
   * Deleting is a decision with a 30-day undo window, not a one-tap action: the
   * note moves to 回收站 rather than vanishing, and the dialog says so. A bare
   * `onDelete` from the menu would be one mis-tap from losing a note out of the
   * grid, which is exactly the failure mode the confirmation exists to prevent.
   */
  private confirmDelete(): void {
    const name = this.title.length > 0 ? this.title : '无标题';
    this.getUIContext().showAlertDialog({
      title: '删除笔记',
      message: `“${name}”将移入回收站，保留 30 天。`,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: $r('app.color.danger'),
        action: () => {
          this.onDelete(this.noteId);
        }
      }
    });
  }

  /**
   * Relative time, deliberately coarse.
   *
   * The grid re-sorts on `updatedAt`, so a precise stamp would tick in place
   * without changing the order; whole units are all the card needs.
   */
  private relativeTime(ms: number): string {
    const now = systemDateTime.getTime();
    const diff = Math.max(0, now - ms);
    const minute = 60 * 1000;
    const hour = 60 * minute;
    const day = 24 * hour;
    if (diff < minute) {
      return '刚刚';
    }
    if (diff < hour) {
      return `${Math.floor(diff / minute)} 分钟前`;
    }
    if (diff < day) {
      return `${Math.floor(diff / hour)} 小时前`;
    }
    if (diff < 2 * day) {
      return '昨天';
    }
    const date = new Date(ms);
    return `${date.getMonth() + 1} 月 ${date.getDate()} 日`;
  }
}
