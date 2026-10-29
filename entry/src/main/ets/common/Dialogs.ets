/**
 * 确认框，集中一处。
 *
 * ## 为什么值得收成一个函数
 *
 * 全应用有 8 个 `showAlertDialog`，每一个都是同样的十二行：`title` / `message` /
 * 一个空的 `primaryButton`（取消，什么都不做）/ 一个 `secondaryButton`（动作）。
 * 抄得多了就会有一处抄错，而这一处的错是**用户按下去才发现**的：
 *
 * - 取消跑到右边、危险动作跑到左边 —— 习惯「右＝确认」的手指会把删除当成取消；
 * - 忘了给 `secondaryButton` 上危险色 —— 删除与归档在视觉上就没有区别了；
 * - `action` 里忘了 `refresh` —— 点了没反应，用户再点一次。
 *
 * 所以这里的两个入口本身就是规则：**默认危险**（`danger`），**强调色是例外**
 * （`accent`）。归档/改名这类可逆动作走 `accent`，删除/清空/移除这类不可逆动作
 * 走 `danger`。第 9 个确认框不要自己写 `showAlertDialog`。
 *
 * ## 为什么取消永远在左、永远是空实现
 *
 * 系统 AlertDialog 的 `primaryButton` 在左。本应用里左侧一律是「取消」——一个
 * 真正什么都不做的按钮，所以它的 `action` 是空的而不是 `hide()`：弹窗由平台在
 * 按钮回调之后自己关，手动再关一次会闪一下。
 *
 * ## 为什么 `okColor` 是参数而不是布尔
 *
 * 强调色是**运行期**的 hex 字符串（`Palette.AccentScheme`，随用户的强调色设置
 * 变化），不能写 `$r('app.color.accent')` 那样在编译期解析。所以颜色必须由调用方
 * 传进来；`danger` / `accent` 两个入口只是把「传什么」这件事替调用方定下来。
 */

export class Dialogs {
  /**
   * 不可逆动作：删除、永久删除、清空、移除标签、移除段落。
   * 确认键染危险色——这是它与「归档」在视觉上唯一的区别，不能省。
   */
  static danger(ui: UIContext, title: string, message: string, okLabel: string,
    onOk: () => void): void {
    Dialogs.open(ui, title, message, okLabel, $r('app.color.danger'), onOk);
  }

  /**
   * 可逆动作：归档、改名、取消归档。
   *
   * 颜色由调用方给：强调色是运行期值（`ReaderPage.accentColor` / `Index.accentColor()`），
   * 这一层拿不到。
   */
  static accent(ui: UIContext, title: string, message: string, okLabel: string,
    okColor: ResourceColor, onOk: () => void): void {
    Dialogs.open(ui, title, message, okLabel, okColor, onOk);
  }

  private static open(ui: UIContext, title: string, message: string, okLabel: string,
    okColor: ResourceColor, onOk: () => void): void {
    ui.showAlertDialog({
      title: title,
      message: message,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: okLabel,
        fontColor: okColor,
        action: onOk
      }
    });
  }
}
