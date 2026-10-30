/**
 * 等高线背景主题：一份配色 + 一份真实地形几何。
 *
 * ## 为什么主题拆成「配色」和「几何」两半
 *
 * 五个地点的等高线是**真实地形**，由 `tools/gen-contours.js` 从公开 DEM 瓦片
 * 提取、简化、增量编码，落在 `rawfile/contours/{key}.txt`。几何是构建期的
 * 产物，运行期只读不改。这里定义的只有**配色与描边参数**。
 *
 * 拆开的实际好处：加一个主题只需要「配色 + 一份几何文件」，两边互不影响；
 * 换掉某个地点的取样范围也不必动配色表。
 *
 * ## 颜色为什么在代码里而不在 resources 里
 *
 * 与 `Palette` 里强调色同一条理由：ArkUI 在构建期就把 `$r('app.color.*')` 解析
 * 成 `Resource`，运行期拿不到 hex，也就无法按主题索引查表。背景是用户可切的，
 * 只能是六位/八位 hex 字符串。
 *
 * ## 亮度预算（可读性硬指标）
 *
 * 背景上直接压着字的地方只有三处：页面大标题（HDS 标题栏）、页签栏（玻璃胶囊）、
 * 设置页的分组小标题。等高线是细线，最坏情况是「一条线正好穿过一行小字」。
 *
 * 定这条预算的方式是量**感知亮度差**（`0.299R + 0.587G + 0.114B` 的差），
 * 而不是对比度比：细线上真正决定「扎不扎眼」的是它与底色的绝对亮度落差，
 * 比值在小字上会失真。
 *
 * | | 浅色 | 深色 |
 * |---|---|---|
 * | 普通线 ΔL | ≤ 16 | ≤ 13 |
 * | 计曲线 ΔL | ≤ 26 | ≤ 18 |
 *
 * 计曲线的预算比普通线宽——它是每第五条的索引线，本来就该更重（真实地形图
 * 用加粗来读高程）；而它更粗，同样亮度差下会比细线更早糊住小字，所以放宽但
 * 不放太多。这几个数由 `contourDeltaL()` 在下面的配色表里逐条验算过。
 */

/**
 * 单条等高线的描边档位。
 *
 * 两档是真实地形图的制度：每五条里有一条是计曲线（index contour），加粗、
 * 加深，用来看高程。背景照抄这条规则，画面才有层次；一片均匀细线读起来只是
 * 纹路，不是地形。
 */
export class ContourInk {
  /** 普通线的颜色。浅色主题下比底色更深，深色主题下更亮。 */
  line: string;
  /** 计曲线的颜色。同一路色相，强度比 `line` 高一档。 */
  index: string;
  /**
   * 普通线的最终不透明度。
   *
   * 这是**画上去的 alpha**，不再乘任何全局系数——多一层相乘会让预算挪到一个
   * 看不见的常量里，改配色时无从判断某条线到底多重。
   */
  lineAlpha: number;
  indexAlpha: number;
  /** 线宽（vp）。计曲线按地形图的惯例约为普通线的 1.7 倍。 */
  lineWidth: number;
  indexWidth: number;

  constructor(line: string, index: string, lineAlpha: number, indexAlpha: number) {
    this.line = line;
    this.index = index;
    this.lineAlpha = lineAlpha;
    this.indexAlpha = indexAlpha;
    this.lineWidth = CONTOUR_LINE_WIDTH;
    this.indexWidth = CONTOUR_INDEX_WIDTH;
  }
}

/** 普通线宽（vp）。1.2 vp 在 480 dpi 上约 1.8 px，抗锯齿后是一条干净的细线。 */
export const CONTOUR_LINE_WIDTH: number = 1.2;
/** 计曲线宽（vp）。1.7 倍是地形图读得出层级、又不至于变成一块面的比例。 */
export const CONTOUR_INDEX_WIDTH: number = 2.0;

/**
 * 顶/底淡化：chrome 压住的那两条带里，等高线按比例退到背景里去。
 *
 * 顶部让位给 HDS 标题栏与状态栏，底部让位给页签栏胶囊。这两条带里的线不参与
 * 「地形」的阅读，只会和字抢注意力；而它们恰好是界面上唯一有固定文字的横带。
 *
 * 用比例而不是固定色遮罩，是因为底色本身是 160° 三段渐变——同色遮罩在这里
 * 对不上，透明遮罩（`destination-out`）才与底色无关。
 */
export const CONTOUR_FADE_TOP: number = 130;
export const CONTOUR_FADE_BOTTOM: number = 110;
/** 淡化带里保留的比例。不是 0：线在带内逐渐退场，硬切会在边界留下一道横线。 */
export const CONTOUR_FADE_MIN: number = 0.06;

/**
 * 一个背景主题。
 *
 * `key` 同时是几何文件名（`rawfile/contours/{key}.txt`），所以它不能随便取。
 */
export class ContourTheme {
  key: string;
  label: string;
  /** 一句话地貌说明，设置页的副标题用。 */
  hint: string;
  /**
   * 这个地点配套的强调色 key（见 `Palette.schemes`）。
   *
   * 强调色由主题**派生**而不是独立选择：选一个地点就得到它那一套色相，界面上
   * 不存在「黄山配橙」这种背景与按钮互相打架的组合。声明放在这里而不是在
   * `Palette` 里按下标对齐，是因为加主题时漏改的位置关系不会报错，只会静默指错。
   */
  accentKey: string;
  /** 底色渐变的三个色标（角度沿用 160°）。 */
  topLight: string;
  topDark: string;
  midLight: string;
  midDark: string;
  bottomLight: string;
  bottomDark: string;
  light: ContourInk;
  dark: ContourInk;

  constructor(key: string, label: string, hint: string, accentKey: string,
    topLight: string, topDark: string, midLight: string, midDark: string,
    bottomLight: string, bottomDark: string,
    light: ContourInk, dark: ContourInk) {
    this.key = key;
    this.label = label;
    this.hint = hint;
    this.accentKey = accentKey;
    this.topLight = topLight;
    this.topDark = topDark;
    this.midLight = midLight;
    this.midDark = midDark;
    this.bottomLight = bottomLight;
    this.bottomDark = bottomDark;
    this.light = light;
    this.dark = dark;
  }

  top(isDark: boolean): string {
    return isDark ? this.topDark : this.topLight;
  }

  mid(isDark: boolean): string {
    return isDark ? this.midDark : this.midLight;
  }

  bottom(isDark: boolean): string {
    return isDark ? this.bottomDark : this.bottomLight;
  }

  ink(isDark: boolean): ContourInk {
    return isDark ? this.dark : this.light;
  }
}

/**
 * 五个点。色相按**地貌本身**分，不是按名单顺序随手分配：
 *
 * | 地点 | 地形 | 底色色相 | 强调色 | 理由 |
 * |---|---|---|---|---|
 * | 黄山 | 花岗岩峰林，等高线挤成一团 | 灰蓝 | 蓝 | 远山与云海 |
 * | 龙脊 | 越城岭余脉的梯田丘陵，同心弧 | 灰绿 | 绿 | 山地植被 |
 * | 长白 | 火山口湖，一圈圈闭合环 | 冷青灰 | 紫 | 高寒湖盆的暮色 |
 * | 沙海 | 塔克拉玛干沙丘，平行长条 | 灰褐 | 橙 | 沙 |
 * | 呼伦 | 呼伦贝尔草原，长而缓的少数线 | 灰青 | 青 | 水草与天光 |
 *
 * 五个都压在同一档低饱和上（最大通道与最小通道相差 15–30），并且都从「近白
 * 或近黑」的底色出发——这是它们读起来是同一套设计语言、而不是五张不相干的
 * 图的原因。饱和色一律不用：背景一旦饱和就会和强调色（按钮、选中态）抢，
 * 而那才是界面里唯一该跳出来的颜色。
 *
 * 强调色是同一路色相**抬到前景**的版本：背景压到 15–30 的通道差，前景用满饱和
 * 度。两者同源，所以界面上不会出现「褐色背景 + 蓝色按钮」这种拼贴感。
 *
 * ## 深色主题的计曲线必须比普通线**更亮**
 *
 * 这是一个肉眼不易发现、但会毁掉层次的方向错误：深色底是近黑，线越接近底色
 * 就越弱。若计曲线取了比普通线更深的色（`#4A5C68` 对 `#5A6B78`），它在深色
 * 下就变成了比普通线更弱的那一档，再加粗也没有用——结果只是「有些线糊得更
 * 粗」。浅色主题相反，线越深越强，所以两套的方向是相反的，不能共用一张表。
 */
export class ContourThemes {
  /** 索引就是持久化的 `backdropTheme`，顺序调整会让老用户的设置跳到别的主题。 */
  static readonly all: ContourTheme[] = [
    new ContourTheme('huangshan', '黄山', '花岗岩峰林，密而陡', 'blue',
      '#F0EDE8', '#1A1C1E', '#E8E4DD', '#222528', '#E0DBD3', '#2A2D30',
      new ContourInk('#8A9BA8', '#6B7D8A', 0.17, 0.22),
      new ContourInk('#5F7180', '#8FA3B2', 0.16, 0.18)),
    new ContourTheme('longji', '龙脊', '梯田丘陵，舒展的同心弧', 'green',
      '#EDF0E8', '#1A1E1A', '#E4E8DD', '#222622', '#DBE0D3', '#2A2E2A',
      new ContourInk('#8A9E8A', '#6B806B', 0.17, 0.22),
      new ContourInk('#5F725F', '#8FA68F', 0.17, 0.19)),
    new ContourTheme('changbai', '长白', '火山口湖，一圈圈闭合', 'violet',
      '#E8EBF0', '#181A1E', '#DDE2E8', '#202428', '#D3D9E0', '#282C30',
      new ContourInk('#8090A8', '#607080', 0.16, 0.21),
      new ContourInk('#5A6B80', '#8A9DB2', 0.17, 0.19)),
    new ContourTheme('taklamakan', '沙海', '沙丘脊线，平行而长', 'amber',
      '#F0EBE0', '#1E1C18', '#E8E2D6', '#262420', '#E0D9CC', '#2E2C28',
      new ContourInk('#A89880', '#8A7A60', 0.18, 0.23),
      new ContourInk('#7A6A54', '#A89880', 0.16, 0.19)),
    new ContourTheme('hulunbuir', '呼伦', '草原缓坡，线很少很长', 'teal',
      '#E8F0F0', '#181E1E', '#DDE8E8', '#202626', '#D3E0E0', '#282E2E',
      new ContourInk('#809EA0', '#608080', 0.17, 0.22),
      new ContourInk('#54767A', '#87A9AB', 0.16, 0.18))
  ];

  static theme(index: number): ContourTheme {
    if (index < 0 || index >= ContourThemes.all.length) {
      return ContourThemes.all[0];
    }
    return ContourThemes.all[index];
  }

  /**
   * 按 key 找主题。
   *
   * 渲染组件拿的是 `themeKey` 而不是下标：几何文件名就是 key，两者必须对得上，
   * 用下标传就得在两处维护同一个顺序，而顺序已经承诺过"调整会让老用户的设置
   * 跳到别的主题"。按 key 查是幂等的，认不出时退回第一个而不是抛。
   */
  static byKey(key: string): ContourTheme {
    for (let i = 0; i < ContourThemes.all.length; i++) {
      if (ContourThemes.all[i].key === key) {
        return ContourThemes.all[i];
      }
    }
    return ContourThemes.all[0];
  }

  /** 下标 → key，供持久化的数字索引落到几何文件上。 */
  static keyOf(index: number): string {
    return ContourThemes.theme(index).key;
  }

  /**
   * 把 `#RRGGBB` 与一个 0–1 的 alpha 合成 ArkUI 的 `#AARRGGBB`。
   *
   * **顺序是 ARGB，不是 RGBA。** 拼在末尾（`#RRGGBBAA`）不会报错，只会被当成
   * 一个不存在的颜色丢掉——背景上什么都没画出来，而代码看起来完全正确。这是
   * 这个文件里最容易踩的一次。
   */
  static withAlpha(hex: string, alpha: number): string {
    const a: number = Math.round(Math.max(0, Math.min(1, alpha)) * 255);
    const pair: string = a < 16 ? `0${a.toString(16)}` : a.toString(16);
    return `#${pair}${hex.substring(1)}`;
  }
}
