/**
 * 动作按钮族。
 *
 * 替代了以下重复实现：
 * - `WebDavPage.ets` 第 214–235 行：两个内联 `Button`（测试连接 / 立即同步），
 *   高 44、圆角 0（默认矩形）、字号 14、无统一 fontWeight。
 * - `TrashPage.ets` 第 95–115 行：两个内联 `Text`（恢复 / 删除），
 *   各自带 padding + backgroundColor + borderRadius，尺寸与 WebDAV 页不一致。
 *
 * 统一后：
 * - 实心/次级成对按钮 → `ActionButton`（高 44、圆角 `RADIUS_CONTROL`、15 Medium）。
 * - 行内文字动作（恢复/删除/清空）→ `TextAction`（12 fp、圆角 `RADIUS_CONTROL`、
 *   `tone` 三档：中性 / 强调 / 危险）。
 *
 * ## `ActionButton` 必须自己声明 `width('100%')`
 *
 * 这条是实测出来的：`Button` 默认是**内容宽**，所以 `.layoutWeight(1)` 拉宽的只是
 * 自定义组件的外壳，里面那个按钮仍缩在左端——在 440 vp 的屏上实测成 92 vp 宽、
 * 中间空出 350 px，读起来是两个小胶囊飘在一条空行里。比例本身没有失效，失效的是
 * 「按钮跟着外壳走」这个假设。
 *
 * 所以宽度写在组件内部，成对使用时直接 `ActionButton({...}).layoutWeight(1)` 即可
 * ——外壳被拉宽，按钮铺满外壳。
 */

import { RADIUS_CONTROL, FONT_SECONDARY } from '../../common/UiTokens';

// ------------------------------------------------------------------
// ActionButton：实心 / 次级 成对按钮
// ------------------------------------------------------------------

@ComponentV2
export struct ActionButton {
  @Param label: string = '';
  @Param primary: boolean = false;
  @Param isEnabled: boolean = true;
  @Param accentColor: string = '#0A59F7';
  @Param onTap: () => void = () => {};

  build() {
    Button(this.label)
      .fontSize(15)
      .fontWeight(FontWeight.Medium)
      .fontColor(this.primary ? $r('app.color.on_accent') : $r('app.color.text_primary'))
      .backgroundColor(this.primary ? this.accentColor : $r('app.color.chip_bg'))
      .width('100%')
      .height(44)
      .borderRadius(RADIUS_CONTROL)
      .enabled(this.isEnabled)
      .opacity(this.isEnabled ? 1 : 0.45)
      .onClick(this.onTap)
  }
}

// ------------------------------------------------------------------
// TextAction：行内文字动作（恢复 / 删除 / 清空 …）
// ------------------------------------------------------------------

/**
 * `TextAction` 的语义档位。
 *
 * 为什么是**三档数字**而不是两个布尔（`danger` + `accent`）：两个布尔就有优先级
 * 问题——同时为真时该画哪个？设置页的 `SegmentButton` 已经用 `kind` 遇到过同一个
 * 问题（三个互斥行会需要三个开关加一条优先级规则），这里的形状与它保持一致。
 *
 * 三档各自对应一种**语义**，不是三种颜色：
 * - `TONE_PLAIN` —— 中性动作（行内的「恢复」用强调色其实是「正向、可做」，见下）。
 * - `TONE_ACCENT` —— 正向动作：恢复、查看、收起。用强调色文字，底是 `chip_bg`。
 * - `TONE_DANGER` —— 不可逆动作：删除、清空、移除。只换颜色，不换尺寸。
 */
export const TONE_PLAIN: number = 0;
export const TONE_ACCENT: number = 1;
export const TONE_DANGER: number = 2;

@ComponentV2
export struct TextAction {
  @Param label: string = '';
  @Param tone: number = TONE_PLAIN;
  @Param filled: boolean = true;
  /** 强调色是运行期 hex，这一层拿不到，由调用方给。只在 `TONE_ACCENT` 时读。 */
  @Param accentColor: string = '#0A59F7';
  @Param onTap: () => void = () => {};

  build() {
    Text(this.label)
      .fontSize(FONT_SECONDARY)
      .fontColor(this.toneColor())
      .padding({ left: 10, right: 10, top: 7, bottom: 7 })
      .backgroundColor(this.filled ? $r('app.color.chip_bg') : Color.Transparent)
      .borderRadius(RADIUS_CONTROL)
      .onClick(this.onTap)
  }

  /** 颜色在构建体内部算：`@Param` 按值参与构建，切档会正常重绘。 */
  private toneColor(): ResourceColor {
    if (this.tone === TONE_DANGER) {
      return $r('app.color.danger');
    }
    if (this.tone === TONE_ACCENT) {
      return this.accentColor;
    }
    return $r('app.color.text_primary');
  }
}
