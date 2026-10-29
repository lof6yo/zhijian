import { TrashEntry } from '../models/Note';
import { NoteStore } from '../services/NoteStore';
import { CARD_CORNER } from '../services/SettingsStore';
import { PageHeader } from '../components/ui/PageHeader';
import { EmptyState } from '../components/ui/EmptyState';
import { TextAction, TONE_ACCENT, TONE_DANGER } from '../components/ui/ActionButton';
import { Toast } from '../common/Toast';
import { Dialogs } from '../common/Dialogs';

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

        // 这一层不再带 `space: 12`：`PageHeader` 自带 56 vp 高度与左右 padding，
        // 再叠 12 vp 间距就等于凭空多出一条空白，把第一行卡片/空态往下推。
        Column() {
          // 页头换成 `PageHeader`：原来是手写的 `Button('‹')` + 24 Bold 标题 + 13 fp「清空」，
          // 与 WebDAV 页各写一遍且字号不同（24 Bold / 16 Medium）。全应用只留一种页头：
          // 56 vp、SymbolGlyph 返回、16 Medium 标题；「清空」仍只在有内容时出现。
          PageHeader({
            title: '回收站',
            subtitle: '删除的笔记保留 30 天',
            trailing: this.entries.length > 0 ? '清空' : '',
            trailingDanger: true,
            onBack: () => {
              this.pathStack.pop();
            },
            onTrailing: () => {
              this.confirmEmpty();
            }
          })

          if (this.entries.length === 0) {
            // 空态换成 `EmptyState`：原来两行灰字且没有图标，分不清「确实是空」还是
            // 「没加载出来」。`fill: true` 自带 `layoutWeight(1)`，保留原来那个占位属性，
            // 也仍然由同一层 `if` 保证空态与列表不会同时渲染。
            EmptyState({
              icon: $r('sys.symbol.trash'),
              title: '回收站是空的',
              hint: '长按笔记卡片可以删除',
              fill: true
            })
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

                    // 行内动作改用 `TextAction`：原来是两段各写一遍 padding/底色/圆角的
                    // `Text`，与 WebDAV 页的成对按钮尺寸对不上。两档语义不同，所以不是
                    // 一个 `danger` 布尔：
                    // 「恢复」是正向动作（原来就是强调色文字 + `chip_bg` 底）→ `TONE_ACCENT`；
                    // 「删除」不可逆且原来无底色 → `TONE_DANGER` + `filled: false`。
                    TextAction({
                      label: '恢复',
                      tone: TONE_ACCENT,
                      accentColor: this.accentColor,
                      onTap: () => {
                        if (this.store().restoreTrash(entry.fileName)) {
                          Toast.show(this.getUIContext(), '已恢复');
                          this.refresh();
                        } else {
                          Toast.show(this.getUIContext(), '恢复失败');
                        }
                      }
                    })
                    TextAction({
                      label: '删除',
                      tone: TONE_DANGER,
                      filled: false,
                      onTap: () => {
                        this.confirmDelete(entry);
                      }
                    })
                  }
                  .width('100%')
                  .padding(14)
                  // 卡片表面走 surface 档（`CARD_CORNER`），与笔记卡片、设置分组卡片同一个数：
                  // 回收站的一行本来也是一张卡片，留一个 16 只会让它在笔记页旁边差 1 vp。
                  .backgroundColor($r('app.color.glass_bg'))
                  .borderRadius(CARD_CORNER)
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

  private confirmDelete(entry: TrashEntry): void {
    // 改走 `Dialogs.danger`：原来这个确认框是手写的十二行，删/清空/移除一共有 8 份，
    // 其中一份忘了给确认键上危险色，删除与归档在视觉上就没有区别了。
    Dialogs.danger(this.getUIContext(), '永久删除',
      `“${entry.title.length > 0 ? entry.title : '无标题'}”将无法恢复。`, '永久删除', () => {
        this.store().deleteTrashForever(entry.fileName);
        this.refresh();
      });
  }

  private confirmEmpty(): void {
    Dialogs.danger(this.getUIContext(), '清空回收站',
      '回收站中的笔记将全部永久删除，无法恢复。', '清空', () => {
        const count = this.store().emptyTrash();
        Toast.show(this.getUIContext(), `已清空 ${count} 篇`);
        this.refresh();
      });
  }
}
