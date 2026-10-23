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
