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

  constructor(key: string, label: string, accentLight: string, accentDark: string,
    onAccentLight: string, onAccentDark: string, chipLight: string, chipDark: string,
    glassLight: string, glassDark: string, glowLight: string, glowDark: string) {
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
}

export class Palette {
  /** Index matches the persisted `accentMode` setting. */
  static readonly schemes: AccentScheme[] = [
    new AccentScheme('blue', '蓝', '#0A59F7', '#8AB4FF', '#FFFFFF', '#0B1020',
      '#E8EEFF', '#1E2A44', '#CC0A59F7', '#558AB4FF', '#330A59F7', '#408AB4FF'),
    new AccentScheme('teal', '青', '#0E8F8F', '#5FD3D3', '#FFFFFF', '#04201F',
      '#DFF4F4', '#123434', '#CC0E8F8F', '#555FD3D3', '#330E8F8F', '#405FD3D3'),
    new AccentScheme('amber', '橙', '#D9700A', '#FFB86B', '#FFFFFF', '#2A1602',
      '#FCEBDC', '#3A2513', '#CCD9700A', '#55FFB86B', '#33D9700A', '#40FFB86B')
  ];

  static scheme(index: number): AccentScheme {
    if (index < 0 || index >= Palette.schemes.length) {
      return Palette.schemes[0];
    }
    return Palette.schemes[index];
  }
}
