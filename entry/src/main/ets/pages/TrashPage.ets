import { TrashEntry } from '../models/Note';
import { NoteStore } from '../services/NoteStore';

@ComponentV2
export struct TrashPage {
  @Param pathStack: NavPathStack = new NavPathStack();
  /** Runtime accent from `Palette` so the page follows the accent setting. */
  @Param accentColor: string = '#0A59F7';
  @Local entries: TrashEntry[] = [];
  @Local version: number = 0;

  aboutToAppear(): void {
    this.refresh();
  }

  build() {
    NavDestination() {
      // Same two-layer split as `EditorPage`: the backdrop expands into the
      // status-bar and gesture-bar bands, the content does not. Without it this
      // page shows the window background above its own `page_bg` (black against
      // `(16,16,18)` in dark mode). Expanding the content `Column` instead would
      // move the header up under the status bar.
      Stack({ alignContent: Alignment.TopStart }) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor($r('app.color.page_bg'))
          .hitTestBehavior(HitTestMode.None)
          .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

        Column({ space: 12 }) {
        Row({ space: 8 }) {
          Button('‹')
            .fontSize(28)
            .fontColor($r('app.color.text_primary'))
            .backgroundColor(Color.Transparent)
            .width(44)
            .height(44)
            .onClick(() => {
              this.pathStack.pop();
            })
          Column({ space: 2 }) {
            Text('回收站')
              .fontSize(24)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
            Text('删除的笔记保留 30 天')
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          if (this.entries.length > 0) {
            Text('清空')
              .fontSize(13)
              .fontColor($r('app.color.danger'))
              .padding({ left: 10, right: 10, top: 6, bottom: 6 })
              .onClick(() => {
                this.confirmEmpty();
              })
          }
        }
        .width('100%')

        if (this.entries.length === 0) {
          Column({ space: 8 }) {
            Text('回收站是空的')
              .fontSize(16)
              .fontColor($r('app.color.text_primary'))
            Text('长按笔记卡片可以删除')
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          List({ space: 8 }) {
            ForEach(this.entries, (entry: TrashEntry) => {
              ListItem() {
                Row({ space: 10 }) {
                  Column({ space: 3 }) {
                    Text(entry.title.length > 0 ? entry.title : '无标题')
                      .fontSize(15)
                      .fontColor($r('app.color.text_primary'))
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(this.deletedLabel(entry.deletedAt))
                      .fontSize(11)
                      .fontColor($r('app.color.text_secondary'))
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)

                  Text('恢复')
                    .fontSize(12)
                    .fontColor(this.accentColor)
                    .padding({ left: 10, right: 10, top: 7, bottom: 7 })
                    .backgroundColor($r('app.color.chip_bg'))
                    .borderRadius(12)
                    .onClick(() => {
                      if (this.store().restoreTrash(entry.fileName)) {
                        this.toast('已恢复');
                        this.refresh();
                      } else {
                        this.toast('恢复失败');
                      }
                    })
                  Text('删除')
                    .fontSize(12)
                    .fontColor($r('app.color.danger'))
                    .padding({ left: 10, right: 10, top: 7, bottom: 7 })
                    .onClick(() => {
                      this.confirmDelete(entry);
                    })
                }
                .width('100%')
                .padding(14)
                .backgroundColor($r('app.color.glass_bg'))
                .borderRadius(16)
                .border({ width: 0.5, color: $r('app.color.glass_border') })
              }
            }, (entry: TrashEntry) => `${entry.fileName}-${this.version}`)
          }
          .layoutWeight(1)
          .width('100%')
        }
        }
        // No `top` inset: `NavDestination` content already starts below the
        // status bar (fullscreen layout is not used), so a manual 48 vp top
        // padding only pushed the header down and wasted the top of the screen.
        .padding({ left: 16, right: 16, bottom: 24 })
        .height('100%')
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .height('100%')
      .width('100%')
    }
    .hideTitleBar(true)
    .onBackPressed(() => {
      this.pathStack.pop();
      return true;
    })
  }

  private store(): NoteStore {
    return NoteStore.instance;
  }

  private refresh(): void {
    this.entries = this.store().trashEntries();
    this.version++;
  }

  private deletedLabel(ms: number): string {
    const date = new Date(ms);
    return `删除于 ${date.getMonth() + 1} 月 ${date.getDate()} 日 · 30 天后自动清除`;
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 1600 });
    } catch (error) {
      // Toast is cosmetic.
    }
  }

  private confirmDelete(entry: TrashEntry): void {
    this.getUIContext().showAlertDialog({
      title: '永久删除',
      message: `“${entry.title.length > 0 ? entry.title : '无标题'}”将无法恢复。`,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '永久删除',
        fontColor: $r('app.color.danger'),
        action: () => {
          this.store().deleteTrashForever(entry.fileName);
          this.refresh();
        }
      }
    });
  }

  private confirmEmpty(): void {
    this.getUIContext().showAlertDialog({
      title: '清空回收站',
      message: '回收站中的笔记将全部永久删除，无法恢复。',
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '清空',
        fontColor: $r('app.color.danger'),
        action: () => {
          const count = this.store().emptyTrash();
          this.toast(`已清空 ${count} 篇`);
          this.refresh();
        }
      }
    });
  }
}
