import { systemDateTime } from '@kit.BasicServicesKit';

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
  @Event onOpen: (noteId: string) => void = () => {};
  @Event onTogglePin: (noteId: string) => void = () => {};
  @Event onToggleFavorite: (noteId: string) => void = () => {};
  @Event onDelete: (noteId: string) => void = () => {};

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
    // Card surface follows the system card colour so light/dark both track the
    // platform, and the 26 vp radius matches the Cube card language.
    .backgroundColor($r('sys.color.ohos_id_color_card_bg'))
    .borderRadius(26)
    .shadow({ radius: 20, color: $r('app.color.glass_shadow'), offsetX: 0, offsetY: 6 })
    .alignItems(HorizontalAlign.Start)
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
      MenuItem({ content: '删除' })
        .contentFontColor($r('app.color.danger'))
        .onClick(() => {
          this.confirmDelete();
        })
    }
  }

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
