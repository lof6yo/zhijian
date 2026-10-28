import { systemDateTime } from '@kit.BasicServicesKit';
import { CardSurface } from './CardSurface';
import { Haptics } from '../common/Haptics';

/**
 * `.background()` takes a typed options object: ArkTS rejects an inline object
 * literal (`arkts-no-untyped-obj-literals`), and the resulting parse failure
 * cascades into the rest of the attribute chain.
 */
const CARD_BG_OPTIONS: BackgroundOptions = { align: Alignment.Center };

/**
 * One 笔记卡片 in the grid.
 *
 * Takes **immutable primitive** props rather than a `Note`. `Note` is
 * `@ObservedV2`, so passing the object through `@Param` would leave the card
 * showing a pre-edit title until the whole grid happened to rebuild; the
 * `ForEach` key `${note.id}-${note.updatedAt}` plus primitive props is what
 * forces a fresh card when an existing note is edited.
 */
@ComponentV2
export struct NoteCard {
  @Param noteId: string = '';
  @Param title: string = '';
  @Param excerpt: string = '';
  @Param tags: string[] = [];
  @Param archived: boolean = false;
  @Param favorite: boolean = false;
  @Param updatedAt: number = 0;
  /** Runtime accent from `Palette`; `$r('app.color.accent')` cannot follow the setting. */
  @Param accentColor: string = '#0A59F7';
  @Param accentChipColor: string = '#E8EEFF';
  /** 强调色面上的文字色（勾选圈里的对勾）。 */
  @Param onAccentColor: string = '#FFFFFF';
  /**
   * 卡片圆角（vp）。固定在 17，与筛选条 / 排序条那条胶囊的半径相同。
   *
   * 仍然是一个 `@Param` 而不是资源：`NoteCard` 不该 import `SettingsStore`，而
   * 资源 `$r('app.*')` 是构建期解析的，圆角一旦要跟着别的东西走（平板、无障碍
   * 大字号），只能是运行期的数。默认值 17 重复写在这里，与 `CARD_CORNER` 对齐。
   */
  @Param cornerRadius: number = 17;
  /**
   * Whether the card paints the platform 沉浸光感 material behind its surface.
   *
   * Gated by the caller rather than probed here, because `uiMaterial` is API 26
   * and this component must keep working below it. When false the card falls
   * back to the opaque system card fill — never to transparent, which would make
   * the note disappear.
   */
  @Param glassOn: boolean = false;
  /** 沉浸光感挡位, 0 = 自适应 … 3 = 低. Fed to `MaterialLayer`. */
  @Param glassGear: number = 0;
  /**
   * A **translucent** veil painted *over* the material, giving the card its
   * surface colour.
   *
   * This is the difference between "glass card" and "no card". The material
   * refracts whatever is behind it, and this app's backdrop is a near-uniform
   * light accent wash — so on its own the material is almost invisible and the
   * grid loses all structure (verified on device: the first build with a bare
   * material carrier made every card the same tone as the page). A frosted veil
   * on top restores the surface while the material still supplies the edge
   * refraction.
   *
   * It must stay translucent: an opaque fill sits above the material's visual
   * layer and hides it completely.
   */
  @Param glassTint: string = '';
  /**
   * 当前是否需要按深色配色绘制。
   *
   * 只用在左右滑动底层的色相强度上：强调色在深色主题下本身是**提亮**过的一档
   * （`Palette.accentDark`），同样的透明度压在近黑的卡面上会一次跳成亮块。滑动
   * 色相是「光」，深色里光应该更弱，不能直接沿用浅色的比例。
   */
  @Param darkTheme: boolean = false;
  /**
   * 多选态。
   *
   * 多选不是「加了一个界面」，而是这张卡片换了一套交互：点一下是**勾选**而不是
   * 打开笔记，左右滑动整个关掉（滑动意味着「对这张卡做一件事」，而在多选里
   * 那件事只由底部的动作条决定），长按菜单保留但去掉「多选」那一项。
   */
  @Param selecting: boolean = false;
  @Param selected: boolean = false;
  @Event onOpen: (noteId: string) => void = () => {};
  @Event onArchive: (noteId: string) => void = () => {};
  @Event onInsight: (noteId: string) => void = () => {};
  @Event onToggleFavorite: (noteId: string) => void = () => {};
  @Event onDelete: (noteId: string) => void = () => {};
  @Event onEditTags: (noteId: string) => void = () => {};
  @Event onExport: (noteId: string) => void = () => {};
  @Event onDuplicate: (noteId: string) => void = () => {};
  /** 多选态下点卡片的回调：切换这张卡的勾选状态。 */
  @Event onToggleSelect: (noteId: string) => void = () => {};

  // ------------------------------------------------------- 左右滑动

  /**
   * 卡片当前的横向位移（vp）。正 = 右滑，负 = 左滑。
   *
   * 卡片被 `translate` 推开的地方露出底下的操作层——这就是邮箱那套交互：
   * **拖动只是「正在考虑」，松手才执行**，没有停住不动的按钮态。
   */
  @Local swipeOffset: number = 0;

  /**
   * 震动去重标记。
   *
   * 触觉只能在**离散的状态切换**上响一次，不能在 `onActionUpdate` 里每帧响。所以
   * 越过判定线不是「每次都响」，而是「第一次越过时响」：字段记住这一拖已经被确认
   * 到哪一档。`onActionStart` 与 `settle()` 之后各清一次，保证连续两次滑动各响一次。
   */
  private buzzedLight: boolean = false;
  private buzzedHeavy: boolean = false;

  /**
   * 卡片实测宽高。操作层要用绝对尺寸，不能用 `'100%'`：
   * 百分比高度在内容驱动的 `Stack` 里按**可用**高度解析，每张卡会被撑成一屏
   * （这个坑在 `MaterialLayer` 上已经踩过一次）。
   */
  @Local cardW: number = 0;
  @Local cardH: number = 0;

  /**
   * 起步死区（vp）。手指横向位移不到这个值，卡片**完全不动**，也不露出底色。
   *
   * `PanGesture.distance` 只决定「手势何时成立」，成立那一刻 `offsetX` 已经不为 0；
   * 若直接把 `offsetX` 写进位移，一次落指抖动就会让卡片闪一下。死区只丢弃这段起始
   * 位移，越过之后仍然赋 `offsetX` 的**原始值**——减去死区会让卡片永远比手指慢
   * 12 vp，看起来就是「追不上手指」。
   */
  private static readonly DEAD_ZONE: number = 12;

  /**
   * 轻档的判定线（vp）。
   *
   * 早先是 24 vp（约一指宽），实测一次快速轻扫 25 vp 就会归档一篇笔记——不是
   * 「滑了」，只是手抖。56 vp 约等于双列卡片（198 vp 宽）的 28%，这个距离已经
   * 不可能被误触出来，也不至于滑不到：重档线在窄卡上是 108 vp（198 × 0.55），
   * 轻档只到它的一半。
   */
  private static readonly LIGHT_THRESHOLD: number = 56;

  /**
   * 第二档的判定线（vp）。
   *
   * 拖到这条线之前是**轻滑**，越过是**重滑**，两档松手执行不同动作。
   * 按卡片宽度的 55% 取，再夹在 96–150：双列卡片只有约 198 vp 宽，固定值会让
   * 窄卡几乎一滑就到、宽卡（平板）又够不着。
   */
  private longThreshold(): number {
    const w: number = this.cardW > 0 ? this.cardW : 198;
    return Math.max(96, Math.min(150, w * 0.55));
  }

  /** 已越过轻档判定线（松手是轻动作，且应当已经响过一声 `soft`）。 */
  private pastLight(): boolean {
    return Math.abs(this.swipeOffset) >= NoteCard.LIGHT_THRESHOLD;
  }

  /**
   * 拖动进度的 0–1。操作层的颜色浓度与图标缩放都挂在这个值上——
   * 「短到长有个过渡」说的就是它：越拉越浓，不是到了某一格才变。
   */
  private pull(): number {
    const limit: number = this.longThreshold() * 1.4;
    return Math.min(1, Math.abs(this.swipeOffset) / limit);
  }

  /** 当前是否已越过第二档判定线（松手就是重滑动作）。 */
  private pastSecond(): boolean {
    return Math.abs(this.swipeOffset) >= this.longThreshold();
  }

  /**
   * 回弹到目标位移。
   *
   * 必须走 `animateTo`：直接赋值会让卡片瞬移，看起来像闪了一下。
   */
  private settle(target: number): void {
    this.getUIContext().animateTo({ duration: 220, curve: Curve.Friction }, () => {
      this.swipeOffset = target;
    });
    // 回弹结束后清标记（而不是在 `onActionEnd` 里立刻清）：`onActionCancel` 等路径
    // 也会走到这里，而一次手势只可能有一次结束。放在这里保证「下一次拖动」从零开始
    // 计数，连续两次滑动各响一次。
    this.buzzedLight = false;
    this.buzzedHeavy = false;
  }

  /**
   * 按当前位移给出触觉反馈。
   *
   * 只在**跨线的那一下**响，靠两个标记去重。两条规则都是刻意的：
   *  - 越线后只在轴向上比较，左右两侧共用同一组标记：一次手势只有一个方向，
   *    中途反向越线（先过 +56 再过 -56）属于罕见操作，多响一声可以接受，漏响不行。
   *  - 两档是**依次**响，不跳级：一次直接拖到重档时也会先响 `soft` 再响 `hard`，
   *    因为轻档动作此刻也已经成立了，用户需要「到第一格」这一下确认，否则从没拖动
   *    直接到删除档会没有任何中间感。
   */
  private buzzForSwipe(): void {
    const dx: number = Math.abs(this.swipeOffset);
    if (!this.buzzedLight && dx >= NoteCard.LIGHT_THRESHOLD) {
      this.buzzedLight = true;
      Haptics.soft();
    }
    if (!this.buzzedHeavy && dx >= this.longThreshold()) {
      this.buzzedHeavy = true;
      Haptics.hard();
    }
  }

  /**
   * 松手时执行动作。
   *
   * 邮箱的分档语义：同一侧滑得近是轻动作，滑得远是重动作。
   *   右滑 → 近：归档（不确认）  远：删除（需确认）
   *   左滑 → 近：收藏（不确认）  远：AI 洞见（不确认）
   * 只有删除要确认：它是唯一不可逆的一档。归档把笔记从「全部」移到「已归档」，
   * 一个筛选条就能拿回来，松手即执行才算「滑一下就有结果」。
   */
  private commitSwipe(rightward: boolean, far: boolean): void {
    if (rightward) {
      if (far) {
        this.confirmDelete();
      } else {
        this.onArchive(this.noteId);
      }
      return;
    }
    if (far) {
      this.onInsight(this.noteId);
    } else {
      this.onToggleFavorite(this.noteId);
    }
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      // 操作层在下，卡片在上。卡片被 `translate` 推开的地方露出这一层。
      if (this.cardW > 0 && this.cardH > 0) {
        this.SwipeLayer()
      }

      Column({ space: 8 }) {
        Row({ space: 6 }) {
        // 多选态的勾选圈。放在标题行**行首**而不是浮在右上角：多选时卡片的内容
        // 不再重要，重要的是「勾了哪几张」，从左侧开始读是唯一不撞上标题的位置。
        if (this.selecting) {
          this.SelectMark()
        }
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

      // 归档徽标放在最底行的右侧，**不进标题行**：标题在 198 vp 的窄卡上本来就
      // 只有两行余量，塞一个 46 vp 的胶囊进去实测把「欢迎使用 纸见」折成
      // 「欢迎使用 纸 / 见」。底行本来就是「时间 + 状态」的位置，空着也是空着。
      Row({ space: 6 }) {
        Text(this.relativeTime(this.updatedAt))
          .fontSize(11)
          .fontColor($r('app.color.text_secondary'))
          .layoutWeight(1)
        if (this.archived) {
          Text('已归档')
            .fontSize(10)
            .fontColor(this.accentColor)
            .backgroundColor(this.accentChipColor)
            .padding({ left: 6, right: 6, top: 1, bottom: 1 })
            .borderRadius(6)
        }
      }
      .width('100%')
      }
      .width('100%')
      .padding(16)
      .alignItems(HorizontalAlign.Start)
      // The surface is painted by `.background()`, in this order:
      //
      //   1. the material carrier (the Toggle that paints 沉浸光感), then
      //   2. a translucent veil, then
      //   3. the text above, as this Column's own children.
      //
      // Both choices are load-bearing.
      //
      // `.background(builder)` lays the carrier out against *this node's* already
      // measured box, so the material cannot inflate the card. Putting the carrier
      // in a `Stack` sibling instead did exactly that on device:
      // `LayoutPolicy.matchParent` resolved against the flow's available size and
      // every card grew to the full grid height — one row filled the screen.
      //
      // The veil has to sit above the material but below the text. Painting it as
      // `backgroundColor` would put it *below* the material, because the material's
      // visual layer is drawn above `backgroundColor`, and hide it entirely.
      .background(this.CardSurface(), CARD_BG_OPTIONS)
      // Transparent only when the carrier is actually painting. An opaque fallback
      // here would be correct-looking but would also cover the material.
      .backgroundColor(this.glassOn ? Color.Transparent : $r('sys.color.ohos_id_color_card_bg'))
      .borderRadius(this.cornerRadius)
      // 勾选后描一圈强调色：只靠标题前那个小圆点，在一屏八张卡里很难一眼扫出
      // 选中了哪几张。
      .border(this.selected
        ? { width: 2, color: this.accentColor }
        : { width: 0 })
      // Press feedback uses the platform interaction effect instead of
      // `.stateStyles()`: this toolchain rejects both the inline object literal
      // and `@Styles` function references as `StateStyles` values.
      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.97 })
      .hoverEffect(HoverEffect.Auto)
      .onClick(() => {
        // 多选态下点卡片 = 勾/取消勾。这里**不能**再走 onOpen：多选途中点开一篇
        // 笔记会让用户丢掉已经选好的那一批。
        if (this.selecting) {
          this.onToggleSelect(this.noteId);
        } else {
          this.onOpen(this.noteId);
        }
      })
      .bindContextMenu(this.CardMenu(), ResponseType.LongPress, {
        preview: MenuPreviewMode.NONE,
        // 菜单弹出时报一声。放在菜单自己的 `onAppear` 而不是某个 `MenuItem.onClick`：
        // 后者会在「选中动作」时再响一次，与点击本身的反馈重复。`onAppear` 是
        // `ContextMenuOptions` 的字段（自 API 12），这里 API 26。
        onAppear: () => {
          Haptics.hard();
        }
      })
      // 横向拖动改由 `PanGesture` 接管；纵向滚动仍旧交给瀑布流。
      .translate({ x: this.swipeOffset })
      .onAreaChange((oldArea: Area, newArea: Area) => {
        const w: number = Number(newArea.width);
        const h: number = Number(newArea.height);
        if (w !== this.cardW || h !== this.cardH) {
          this.cardW = w;
          this.cardH = h;
        }
      })
      // 用**默认**的 `.gesture`，不是 `priorityGesture` 也不是 `parallelGesture`。
      //   - `parallelGesture` 让滑动和长按菜单**同时**成立，慢拖时菜单会在页面中央
      //     弹出来（实测）。
      //   - `priorityGesture` 反过来把长按菜单留在原地、滑动不触发（实测：卡片纹丝
      //     不动，菜单照样弹出）。
      // 默认绑定走平台自己的竞争规则：手指移动超过 `distance` 即判定为滑动，
      // 长按随之取消；按住不动才轮到菜单。「按住不动 = 菜单，移动 = 滑动」。
      .gesture(
        PanGesture({ fingers: 1, direction: PanDirection.Horizontal, distance: 12 })
          .onActionStart(() => {
            this.swipeOffset = 0;
            // 每一次手势都从「还没响过」开始。
            this.buzzedLight = false;
            this.buzzedHeavy = false;
          })
          .onActionUpdate((event: GestureEvent) => {
            // 多选态里左右滑动整块关掉：滑动在这里没有可执行的动作（归档 / 删除
            // 都由底部动作条统一决定），留着它只会让「想勾选」的手指滑出一张卡的
            // 动作提示，然后弹回原样。
            if (this.selecting) {
              return;
            }
            // `offsetX` 是相对起手点的位移（vp，正值向右），不是逐帧增量，
            // 所以直接赋值，不累加。
            //
            // 死区内保持 0：手势在 `distance` 上刚成立时 `offsetX` 通常只有几 vp，
            // 把它写进位移会让卡片「抖一下」并露出一条底色。越过后赋**原始值**，
            // 不减死区——减了之后位移与手指就不再 1:1，视觉上追不上手指。
            if (Math.abs(event.offsetX) < NoteCard.DEAD_ZONE) {
              this.swipeOffset = 0;
              return;
            }
            const limit: number = this.cardW > 0 ? this.cardW : 198;
            this.swipeOffset = Math.max(-limit, Math.min(limit, event.offsetX));
            this.buzzForSwipe();
          })
          .onActionEnd(() => {
            if (this.selecting) {
              return;
            }
            const dx: number = this.swipeOffset;
            // 邮箱式分档：滑出去就要有结果。轻档门槛 56 vp（约双列卡片的 28%）——
            // 低于它一律当误触：回弹到 0，**不执行任何动作**。松手永远回到 0，
            // 没有停住的按钮态。
            if (Math.abs(dx) >= NoteCard.LIGHT_THRESHOLD) {
              this.commitSwipe(dx > 0, Math.abs(dx) >= this.longThreshold());
            }
            this.settle(0);
          })
          // 手势被打断（多指、系统手势、切页签）也必须回弹。少了这一条，卡片会
          // 停在半路——`onActionEnd` 是唯一回弹的地方，而它不会在被打断时触发。
          .onActionCancel(() => {
            this.settle(0);
          })
      )
    }
    // 卡片根节点自己声明宽度：`FlowItem` 的子节点是按**整条流**测量的，
    // 不钉宽度，`'100%'` 会解析成两列的宽度并盖住邻居。
    .width('100%')
  }

  /**
   * 强调色色相的强度（0–1）。
   *
   * 只有强调色需要这个函数：它是运行期从 `Palette` 读来的 hex，浅深两套色值在
   * 代码里，透明度只能跟着算。收藏金与危险红是**资源色**，透明度已经写进
   * `swipe_gold_hi/mid/lo`、`swipe_red_hi/mid/lo`，由 `resources/dark/` 给出
   * 深色的一套——两条色相总跟着主题走，不会像常量那样只在一种模式下正确。
   *
   * 深色仍要再弱一档：`Palette.accentDark` 本身是提亮过的，同一个比例压在近黑
   * 卡面上会直接跳成一块亮色。
   */
  private accentAlpha(strong: boolean): number {
    if (this.darkTheme) {
      return strong ? 0.16 : 0.09;
    }
    return strong ? 0.22 : 0.11;
  }

  /**
   * 把 `#RRGGBB` / `#AARRGGBB` 改成带指定不透明度的 ARGB。
   *
   * ArkUI 的 `linearGradient` 只能收 ARGB 字符串，而强调色是运行期从 `Palette`
   * 读来的普通 hex，没法写进资源表。渐变的收尾端必须是**同色相的 alpha 0**，
   * 不能用 `Color.Transparent`：后者在非预乘插值里会中途往黑里沉，露出一道灰。
   */
  private withAlpha(hex: string, alpha: number): string {
    const a: number = Math.round(Math.max(0, Math.min(1, alpha)) * 255);
    const aHex: string = a.toString(16).padStart(2, '0').toUpperCase();
    if (hex.length === 9 && hex.startsWith('#')) {
      return '#' + aHex + hex.substring(3);
    }
    if (hex.length === 7 && hex.startsWith('#')) {
      return '#' + aHex + hex.substring(1);
    }
    return hex;
  }

  /**
   * 卡片底下的操作层——邮箱式，不是按钮式。
   *
   * 三条约束，都是为了「不割裂」：
   *
   *  1. **形状就是卡片本身。** 整块与卡片同尺寸、同圆角，卡片从它上面滑过去；
   *     露出来的永远是「这张卡自己的边缘」。早先按露出宽度画窄条，窄的时候圆角
   *     被夹成尖角薄片，像一块从别处飘来的颜色。
   *  2. **底色是同一张纸。** 先铺卡片自己的表面色，再叠色相——直接坐在页面背景
   *     上的纯色会被读成「另一张卡」，不是「这张卡底下的一层」。
   *  3. **色相从露出侧往里淡出。** 平铺一块色会有一条和卡片边缘齐平的硬色边，
   *     那就是跳。渐变到底之后，色只是从卡片底下渗出来的一点光。
   *
   * 一层两档：越过判定线后同一层加深一档、图标放大、文案换成重动作。跨线是唯一
   * 离散的那一下，其余随拉动连续变化。
   *
   * 所有值都直接读 `@Local`，不经 `@Builder` 参数：参数按值传递，运行时变化的
   * 字段进不了依赖，拖动时这一层就不会重画。
   */
  @Builder
  SwipeLayer() {
    Stack() {
      if (this.swipeOffset > 0) {
        this.StartLayer()
      }
      if (this.swipeOffset < 0) {
        this.EndLayer()
      }
    }
    .width(this.cardW)
    .height(this.cardH)
    // 圆角与裁剪**只在这里做一次**，且用的是与卡片相同的半径。
    //
    // 这一条改过两次才对。原先把圆角放在「色相条」自己身上（宽度 = 露出宽度），
    // 而 ArkUI 的 `clip(true)` + `borderRadius` 在容器**窄于两倍半径**时，两个圆角
    // 会被挤在一起、半径被压小：露出 30 vp、半径 16 vp（2r = 32 > 30）时，弧线明显
    // 向内收，于是露出侧那条弧和卡片自己的弧对不上——滑动时看得到的那条「错位边框」。
    // 露出越少越明显，正是「微微看到」。
    //
    // 放到这块**整卡大小**的容器上就不会发生：宽度恒为 cardW，弧永远是那一条。色相条
    // 因此不再需要自己的圆角，它的左（右）边缘由这里的弧裁出来，与卡片轮廓严格重合。
    .borderRadius(this.cornerRadius)
    .clip(true)
    .hitTestBehavior(HitTestMode.None)
  }

  /** 右滑：轻 = 归档（强调色光），重 = 删除（红光）。 */
  @Builder
  StartLayer() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 第 1 层：卡片自己的表面色。底下这一层必须是「纸」，否则纯色坐在页面
      // 背景上会被读成另一张卡，而不是这张卡底下的一层。
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.glassOn ? this.glassTint : $r('sys.color.ohos_id_color_card_bg'))
        .borderRadius(this.cornerRadius)
      // 第 2 层：色相。**只铺在真正露出来的那一条上**，并在卡片边缘处淡到零；
      // 铺满整张卡时，露出来的永远是渐变里最深的那一段，看起来就是一块色板。
      // 这里**不给这一条自己设圆角**——外层的 `clip(true)` 会用与卡片完全相同的
      // 半径裁它，两者才是同一条弧；单独给圆角会被窄宽度夹成更小的半径，弧线
      // 向内收，露出侧就多出一条与卡片边缘对不上的弧（实测可见）。
      Column()
        .width(Math.abs(this.swipeOffset))
        .height('100%')
        .linearGradient({
          angle: 90,
          colors: this.pastSecond()
            ? [[$r('app.color.swipe_red_hi'), 0.0],
               [$r('app.color.swipe_red_mid'), 0.55],
               [$r('app.color.swipe_red_lo'), 1.0]]
            : [[this.withAlpha(this.accentColor, this.accentAlpha(false)), 0.0],
               [this.withAlpha(this.accentColor, this.accentAlpha(false) * 0.4), 0.55],
               [this.withAlpha(this.accentColor, 0), 1.0]]
        })

      Column({ space: 4 }) {
        // 露出太窄时只留一层染色：16 fp 的图标塞进十几 vp 里会溢出到卡片外面。
        if (Math.abs(this.swipeOffset) >= 30) {
          if (this.pastSecond()) {
            SymbolGlyph($r('sys.symbol.trash'))
              .fontSize(this.stripIconSize())
              .fontColor([$r('app.color.danger')])
          } else {
            SymbolGlyph($r('sys.symbol.archivebox'))
              .fontSize(this.stripIconSize())
              .fontColor([this.accentColor])
          }
        }
        // 10 fp 的文案需要更宽的位置，窄了就只显示图标。
        if (Math.abs(this.swipeOffset) >= 56) {
          Text(this.pastSecond() ? '删除' : (this.archived ? '取消归档' : '归档'))
            .fontSize(10)
            .fontColor(this.pastSecond() ? $r('app.color.danger') : this.accentColor)
            .maxLines(1)
        }
      }
      .width(Math.abs(this.swipeOffset))
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
  }

  /** 左滑：轻 = 收藏（暖光），重 = AI 洞见（强调色光）。 */
  @Builder
  EndLayer() {
    Stack({ alignContent: Alignment.TopEnd }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.glassOn ? this.glassTint : $r('sys.color.ohos_id_color_card_bg'))
        .borderRadius(this.cornerRadius)
      // 同 `StartLayer`：色相条自己不设圆角，交给外层 `clip(true)` 用卡片半径
      // 裁一次，两端弧线才与卡片轮廓重合。
      Column()
        .width(Math.abs(this.swipeOffset))
        .height('100%')
        .linearGradient({
          angle: 270,
          colors: this.pastSecond()
            ? [[this.withAlpha(this.accentColor, this.accentAlpha(true)), 0.0],
               [this.withAlpha(this.accentColor, this.accentAlpha(true) * 0.42), 0.55],
               [this.withAlpha(this.accentColor, 0), 1.0]]
            : [[$r('app.color.swipe_gold_hi'), 0.0],
               [$r('app.color.swipe_gold_mid'), 0.55],
               [$r('app.color.swipe_gold_lo'), 1.0]]
        })

      Column({ space: 4 }) {
        if (Math.abs(this.swipeOffset) >= 30) {
          if (this.pastSecond()) {
            SymbolGlyph($r('sys.symbol.wand_and_stars'))
              .fontSize(this.stripIconSize())
              .fontColor([this.accentColor])
          } else {
            Text('★')
              .fontSize(this.stripIconSize())
              .fontColor($r('app.color.favorite'))
          }
        }
        if (Math.abs(this.swipeOffset) >= 56) {
          Text(this.pastSecond() ? 'AI 洞见' : (this.favorite ? '取消收藏' : '收藏'))
            .fontSize(10)
            .fontColor(this.pastSecond() ? this.accentColor : $r('app.color.favorite'))
            .maxLines(1)
        }
      }
      .width(Math.abs(this.swipeOffset))
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
  }

  /**
   * 图标随拉动放大。
   *
   * 这是「短到长有过渡」里连续的那一半：底色只是在跨线时加深一档，尺寸一直在长。
   */
  private stripIconSize(): number {
    return 16 + 6 * this.pull();
  }

  /**
   * Background layer: the shared card surface (沉浸光感 + 半透明遮罩).
   *
   * Settings 分组卡片用的是同一个 `CardSurface`——两处的圆角、材质强度与遮罩
   * 浓度必须一致，否则设置页看起来像另一个应用里的控件。
   */
  @Builder
  CardSurface() {
    CardSurface({
      radius: this.cornerRadius,
      glassOn: this.glassOn,
      glassGear: this.glassGear,
      glassTint: this.glassOn ? this.glassTint : ''
    })
  }

  /** 多选态的勾选圈：未选是空心环，选中是实心强调色 + 对勾。 */
  @Builder
  SelectMark() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.selected) {
        Column()
          .width(20)
          .height(20)
          .borderRadius(10)
          .backgroundColor(this.accentColor)
        SymbolGlyph($r('sys.symbol.checkmark'))
          .fontSize(12)
          .fontColor([this.onAccentColor])
      } else {
        Column()
          .width(20)
          .height(20)
          .borderRadius(10)
          .border({ width: 1.5, color: $r('app.color.text_secondary') })
      }
    }
    .width(20)
    .height(20)
    .accessibilityText(this.selected ? '已选中' : '未选中')
  }

  @Builder
  CardMenu() {
    Menu() {
      if (this.selecting) {
        // 多选途中「多选」这一项没有意义（已经在里面了），而且菜单本身会挡住
        // 底部动作条；只留单项动作，其余交给动作条。
        MenuItem({ content: '取消多选' })
          .contentFontColor($r('app.color.text_primary'))
          .onClick(() => {
            this.onToggleSelect(this.noteId);
          })
      } else {
        MenuItem({ content: this.archived ? '取消归档' : '归档' })
          .contentFontColor($r('app.color.text_primary'))
          .onClick(() => {
            // 菜单保留确认：划动手势是「甩一下就完事」，弹框会打断那个节奏，所以
            // 右滑轻档直接执行；而点开菜单本身就是一次停顿，这里问一句不碍事。
            // 取消归档两条入口都不问——它只是把笔记拿回来。
            if (this.archived) {
              this.onArchive(this.noteId);
            } else {
              this.confirmArchive();
            }
          })
        MenuItem({ content: this.favorite ? '取消收藏' : '收藏' })
          .contentFontColor($r('app.color.text_primary'))
          .onClick(() => {
            this.onToggleFavorite(this.noteId);
          })
        MenuItem({ content: '标签…' })
          .contentFontColor($r('app.color.text_primary'))
          .onClick(() => {
            this.onEditTags(this.noteId);
          })
        MenuItem({ content: '导出 MD' })
          .contentFontColor($r('app.color.text_primary'))
          .onClick(() => {
            this.onExport(this.noteId);
          })
        MenuItem({ content: '创建副本' })
          .contentFontColor($r('app.color.text_primary'))
          .onClick(() => {
            this.onDuplicate(this.noteId);
          })
        MenuItem({ content: '多选' })
          .contentFontColor($r('app.color.text_primary'))
          .onClick(() => {
            this.onToggleSelect(this.noteId);
          })
        MenuItem({ content: '删除' })
          .contentFontColor($r('app.color.danger'))
          .onClick(() => {
            this.confirmDelete();
          })
      }
    }
  }

  /**
   * 归档确认框。只给**长按菜单**用——划动右滑轻档直接执行（松手即结果，
   * 弹框会把「甩一下就完事」打断）。归档是可逆的：笔记从「全部」移到
   * 「已归档」，点一下筛选条就能拿回来，所以手势那边不值得再问一句。
   */
  private confirmArchive(): void {
    const name = this.title.length > 0 ? this.title : '无标题';
    this.getUIContext().showAlertDialog({
      title: '归档笔记',
      message: `“${name}”会从「全部」移到「已归档」，随时可以恢复。`,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '归档',
        fontColor: this.accentColor,
        action: () => {
          this.onArchive(this.noteId);
        }
      }
    });
  }

  /**
   * Deleting is a decision with a 30-day undo window, not a one-tap action: the
   * note moves to 回收站 rather than vanishing, and the dialog says so. A bare
   * `onDelete` from the menu would be one mis-tap from losing a note out of the
   * grid, which is exactly the failure mode the confirmation exists to prevent.
   */
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

  /**
   * Relative time, deliberately coarse.
   *
   * The grid re-sorts on `updatedAt`, so a precise stamp would tick in place
   * without changing the order; whole units are all the card needs.
   */
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
