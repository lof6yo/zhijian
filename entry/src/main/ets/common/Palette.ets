/**
 * Runtime-switchable accent colors.
 *
 * ArkUI resolves `$r('app.color.*')` from the resource table at build time, so a
 * user-selected accent cannot be expressed as a resource. Every accent-dependent
 * color therefore lives here as a plain hex string, with an explicit light and
 * dark variant so dark mode keeps AA contrast instead of reusing the saturated
 * light-mode hue.
 *
 * ## 强调色不是独立的设置项，它由背景主题派生
 *
 * 用户选「沙海」，整套强调色就变成陶土橙；选「长白」，变成冷紫。**没有第二个
 * 开关**——若强调色还能单独选，屏幕上就会出现「黄山 + 橙」这种与地形色相打架的
 * 组合，而「自动适配」也就成了一句做不到的承诺。派生关系写在
 * `ContourTheme.accentKey` 上（每个地点声明自己的色相），这里只负责按 key 查表。
 *
 * 代价是强调色的可选范围跟着主题走（五套），而不再是一份独立的色板。收益是
 * 一致性：整个界面的唯一饱和色永远与背景的地貌色相互相呼应，而不是互相抢。
 *
 * ## 为什么字段只有这一组
 *
 * `glow*` / `page*` / `glass*` 三组曾经在这里：光斑颜色、背景渐变三段、以及
 * 玻璃选中底。前两组随「背景改成等高线主题」一起失去读者（底色与光斑都不再由
 * 强调色染），第三组从来没被读过（`glassBg()` 无调用点）。留着三个没有读者的
 * 十八参数字段，只会让新增第五套配色时不得不凭空发明十二个没人看的 hex——所以
 * 一并删掉。要恢复光斑，重新设计那一层，不要把它接回这张表。
 */
export class AccentScheme {
  /** 与 `ContourTheme.accentKey` 对应。 */
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

  constructor(key: string, label: string, accentLight: string, accentDark: string,
    onAccentLight: string, onAccentDark: string, chipLight: string, chipDark: string) {
    this.key = key;
    this.label = label;
    this.accentLight = accentLight;
    this.accentDark = accentDark;
    this.onAccentLight = onAccentLight;
    this.onAccentDark = onAccentDark;
    this.chipLight = chipLight;
    this.chipDark = chipDark;
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
}

export class Palette {
  /**
   * 五套强调色，与 `ContourThemes.all` 的地点一一对应（顺序不必相同，靠 key 关联）。
   *
   * 色相按地点的地貌色温挑：
   *
   * | 地点 | 强调色 | 理由 |
   * |---|---|---|
   * | 黄山 | 蓝 `#0A59F7` | 云海与远山的冷蓝 |
   * | 龙脊 | 绿 `#2E7D4F` | 梯田植被 |
   * | 长白 | 紫 `#7452C8` | 高寒湖盆的暮色，也避开与黄山同为蓝 |
   * | 沙海 | 橙 `#D9700A` | 沙 |
   * | 呼伦 | 青 `#0E8F8F` | 水草与天光 |
   *
   * 深色一套统一提亮并降饱和（`#2E7D4F` 压在近黑底上会读不出来），同时把
   * `onAccent` 反过来压到近黑——白字压在 `#6FD39A` 上只有 1.8:1。
   */
  static readonly schemes: AccentScheme[] = [
    new AccentScheme('blue', '蓝', '#0A59F7', '#8AB4FF', '#FFFFFF', '#0B1020',
      '#E8EEFF', '#1E2A44'),
    new AccentScheme('green', '绿', '#2E7D4F', '#6FD39A', '#FFFFFF', '#06240F',
      '#E4F3E8', '#173220'),
    new AccentScheme('violet', '紫', '#7452C8', '#B79BF0', '#FFFFFF', '#150A2A',
      '#EEE8FB', '#241B38'),
    new AccentScheme('amber', '橙', '#D9700A', '#FFB86B', '#FFFFFF', '#2A1602',
      '#FCEBDC', '#3A2513'),
    new AccentScheme('teal', '青', '#0E8F8F', '#5FD3D3', '#FFFFFF', '#04201F',
      '#DFF4F4', '#123434')
  ];

  static scheme(index: number): AccentScheme {
    if (index < 0 || index >= Palette.schemes.length) {
      return Palette.schemes[0];
    }
    return Palette.schemes[index];
  }

  /**
   * key → 下标。认不出时退回 0（蓝），与 `scheme()` 的归一方向一致。
   *
   * 用 key 而不是「主题下标 % 3」来关联：主题会增删，而位置关系一旦被当成契约，
   * 加第六个地点就会把它静默指到别人家的强调色上。
   */
  static indexOf(key: string): number {
    for (let i = 0; i < Palette.schemes.length; i++) {
      if (Palette.schemes[i].key === key) {
        return i;
      }
    }
    return 0;
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
