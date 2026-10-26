/**
 * Runtime-switchable accent colors.
 *
 * ArkUI resolves `$r('app.color.*')` from the resource table at build time, so a
 * user-selected accent cannot be expressed as a resource. Every accent-dependent
 * color therefore lives here as a plain hex string, with an explicit light and
 * dark variant so dark mode keeps AA contrast instead of reusing the saturated
 * light-mode hue.
 */
export class AccentScheme {
  key: string;
  label: string;
  /** Saturated hue for the light theme. */
  accentLight: string;
  /** Desaturated, lightened hue for the dark theme. */
  accentDark: string;
  /** Text/icon color drawn on top of the accent fill. */
  onAccentLight: string;
  onAccentDark: string;
  /** Soft tint behind chips, used instead of a translucent accent fill. */
  chipLight: string;
  chipDark: string;
  /** Selected-segment / filter fill. */
  glassLight: string;
  glassDark: string;
  /** FAB halo. */
  glowLight: string;
  glowDark: string;
  /**
   * Backdrop gradient endpoints. These are what make 光感 follow the accent:
   * the page is a two-stop wash of the accent's own hue, so switching 强调色
   * recolours the whole canvas instead of leaving a fixed blue sky behind a
   * teal UI.
   *
   * The stops are deliberately *much* paler than `accent` — a page painted at
   * accent strength makes the cards unreadable. Light mode keeps them near-white
   * with a hue bias; dark mode keeps them near-black with the same bias, so the
   * text keeps its contrast either way.
   */
  pageTopLight: string;
  pageTopDark: string;
  pageMidLight: string;
  pageMidDark: string;
  pageBottomLight: string;
  pageBottomDark: string;

  constructor(key: string, label: string, accentLight: string, accentDark: string,
    onAccentLight: string, onAccentDark: string, chipLight: string, chipDark: string,
    glassLight: string, glassDark: string, glowLight: string, glowDark: string,
    pageTopLight: string, pageTopDark: string, pageMidLight: string, pageMidDark: string,
    pageBottomLight: string, pageBottomDark: string) {
    this.key = key;
    this.label = label;
    this.accentLight = accentLight;
    this.accentDark = accentDark;
    this.onAccentLight = onAccentLight;
    this.onAccentDark = onAccentDark;
    this.chipLight = chipLight;
    this.chipDark = chipDark;
    this.glassLight = glassLight;
    this.glassDark = glassDark;
    this.glowLight = glowLight;
    this.glowDark = glowDark;
    this.pageTopLight = pageTopLight;
    this.pageTopDark = pageTopDark;
    this.pageMidLight = pageMidLight;
    this.pageMidDark = pageMidDark;
    this.pageBottomLight = pageBottomLight;
    this.pageBottomDark = pageBottomDark;
  }

  accent(isDark: boolean): string {
    return isDark ? this.accentDark : this.accentLight;
  }

  onAccent(isDark: boolean): string {
    return isDark ? this.onAccentDark : this.onAccentLight;
  }

  chipBg(isDark: boolean): string {
    return isDark ? this.chipDark : this.chipLight;
  }

  glassBg(isDark: boolean): string {
    return isDark ? this.glassDark : this.glassLight;
  }

  glow(isDark: boolean): string {
    return isDark ? this.glowDark : this.glowLight;
  }

  pageTop(isDark: boolean): string {
    return isDark ? this.pageTopDark : this.pageTopLight;
  }

  pageMid(isDark: boolean): string {
    return isDark ? this.pageMidDark : this.pageMidLight;
  }

  pageBottom(isDark: boolean): string {
    return isDark ? this.pageBottomDark : this.pageBottomLight;
  }
}

export class Palette {
  /** Index matches the persisted `accentMode` setting. */
  static readonly schemes: AccentScheme[] = [
    new AccentScheme('blue', '蓝', '#0A59F7', '#8AB4FF', '#FFFFFF', '#0B1020',
      '#E8EEFF', '#1E2A44', '#CC0A59F7', '#558AB4FF', '#330A59F7', '#408AB4FF',
      '#EAF1F8', '#1B2530', '#F6F9FC', '#1B1F29', '#E8EEFF', '#101114'),
    new AccentScheme('teal', '青', '#0E8F8F', '#5FD3D3', '#FFFFFF', '#04201F',
      '#DFF4F4', '#123434', '#CC0E8F8F', '#555FD3D3', '#330E8F8F', '#405FD3D3',
      '#E6F4F4', '#14302F', '#F4FAFA', '#16262A', '#DFF2F2', '#0E1414'),
    new AccentScheme('amber', '橙', '#D9700A', '#FFB86B', '#FFFFFF', '#2A1602',
      '#FCEBDC', '#3A2513', '#CCD9700A', '#55FFB86B', '#33D9700A', '#40FFB86B',
      '#FAF0E6', '#30231A', '#FCF7F2', '#29201B', '#FBEBDA', '#14100D')
  ];

  static scheme(index: number): AccentScheme {
    if (index < 0 || index >= Palette.schemes.length) {
      return Palette.schemes[0];
    }
    return Palette.schemes[index];
  }
}

/**
 * 标签药丸的「热度」色阶：用蓝 → 绿 → 黄 → 红表示这个标签下有多少篇笔记。
 *
 * ## 为什么不走 `$r('app.color.*')`
 *
 * 药丸的底色是这一档色相的**低不透明度版本**，而透明度必须由代码算（同一个色相
 * 在玻璃胶囊里要 12%，在没有材质时又要更低）。ArkUI 的 `$r()` 返回的是
 * `Resource`，拿不到 hex 也就没法派生；这与强调色的处理是同一个理由。
 *
 * ## 为什么是一场固定四档，而不是连续的色相插值
 *
 * 连续插值会产生「差一篇笔记就换个颜色」的错觉，而用户要读的是**量级**：
 * 这个标签是冷门还是主力。四档分别在语义上是「少量 / 一些 / 较多 / 最多」，
 * 中间值由 `TagHeat.bucket()` 归并。
 */
export class TagHeat {
  /** 冷 → 热。浅色主题下是在白底上仍然可读的饱和色。 */
  static readonly huesLight: string[] = ['#0A59F7', '#1E8E3E', '#C77700', '#D92C2C'];
  /** 深色主题：同一路色相提亮，否则 #1E8E3E 压在近黑底上读不出来。 */
  static readonly huesDark: string[] = ['#8AB4FF', '#6BD69A', '#FFC24D', '#FF6B6B'];

  /**
   * 篇数 → 档位（0–3）。
   *
   * **两个尺度同时成立，取较小值**：
   *
   * - **绝对档**回答「这个标签本身重不重要」：1 篇是「少量」，2–3 篇「一些」，
   *   4–6 篇「较多」，7 篇以上才是「最多」。没有它，一个只有两个标签、各 1–2 篇
   *   的库里也会有一半被染成红色（实测：`# 示例` 2 篇就变红了）——用户读到的
   *   是「红 = 最重要」，而 2 篇在任何库里都不重要。
   * - **相对档**回答「在这个库里算不算多」：最高篇数是参照系，一个 30 篇的库里
   *   5 篇确实只是「较少」，即使它按绝对档会落到第二档。
   *
   * 取较小值意味着：**颜色偏冷是安全的方向**，偏热必须有绝对数量支撑。
   * 一处特判：0 篇（只在名录里存在）永远是最冷的一档。
   */
  static bucket(count: number, maxCount: number): number {
    if (count <= 0 || maxCount <= 1) {
      return 0;
    }
    const absolute: number = TagHeat.absoluteBucket(count);
    const relative: number = TagHeat.relativeBucket(count, maxCount);
    return Math.min(absolute, relative);
  }

  /**
   * 只看篇数本身的档位。
   *
   * 阈值按「一个笔记库里一个标签通常有几篇」定：1 篇是偶然用了一次，2–3 篇算「有几
   * 篇」，4–6 篇已经是一条常用线索，7 篇以上基本就是主线题材。上限没有定到 10+：
   * 一个用了半年的库很少有过十篇的标签，那条边界实际永远触发不到，红色会变成死档。
   */
  private static absoluteBucket(count: number): number {
    if (count <= 1) {
      return 0;
    }
    if (count <= 3) {
      return 1;
    }
    if (count <= 6) {
      return 2;
    }
    return 3;
  }

  /** 相对全场最高篇数的档位。 */
  private static relativeBucket(count: number, maxCount: number): number {
    const ratio: number = count / maxCount;
    if (ratio < 0.25) {
      return 0;
    }
    if (ratio < 0.5) {
      return 1;
    }
    if (ratio < 0.75) {
      return 2;
    }
    return 3;
  }

  static hue(bucket: number, isDark: boolean): string {
    const table: string[] = isDark ? TagHeat.huesDark : TagHeat.huesLight;
    if (bucket < 0 || bucket >= table.length) {
      return table[0];
    }
    return table[bucket];
  }
}
