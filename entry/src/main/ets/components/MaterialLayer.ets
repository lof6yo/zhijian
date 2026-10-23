import { uiMaterial } from '@kit.ArkUI';

/**
 * A carrier layer that paints the platform's 沉浸光感 material behind arbitrary
 * content.
 *
 * ## Why a `Toggle` and not `systemMaterial()` on the content itself
 *
 * `systemMaterial` is declared on `CommonMethod`, so it type-checks on any
 * component — but the platform only *renders* it in a fixed set of scopes: a
 * `Navigation`/`NavDestination` title bar, a `barPosition(End)` bottom tab bar,
 * and the listed control families (Button / Select / Toggle / Slider /
 * ChipGroup / SegmentButton). The `@ohos.arkui.uiMaterial` docs put it plainly:
 * "在其他区域中设置沉浸光感效果不生效". Measured on this app: a chip capsule in page
 * content with `.backgroundColor(Color.Red).systemMaterial(...)` kept the red
 * fill, i.e. the material never applied.
 *
 * `Toggle` *is* in that list. So instead of asking the card to paint the
 * material, we put an invisible, non-interactive `Toggle` behind the content and
 * let it paint. The content draws on top. This is the only way to get real
 * immersive material on a card, chip, sheet or input that lives in page content.
 *
 * ## Properties that are all load-bearing
 *
 * 1. `width/height(LayoutPolicy.matchParent)` — **not** `'100%'`. A percentage
 *    inside a `Stack` resolves against the parent's available size, which
 *    inflates the card and pushes its neighbours around.
 * 2. `borderRadius` matching the shell — `ToggleType.Button` draws its *own*
 *    button chrome (a rounded rect plus a stroke). If that radius is smaller than
 *    the shell's, a smaller-radius rim appears inset inside the card.
 * 3. `backgroundColor(Color.Transparent)` — the material's visual layer sits
 *    *below* `backgroundColor`, so an opaque fill covers it completely.
 * 4. Non-interactive: `enabled(false)` + `focusable(false)` +
 *    `accessibilityLevel('no')` + `hitTestBehavior(HitTestMode.None)`. Otherwise
 *    the carrier steals taps that belong to the card.
 * 5. `attributeModifier` applied **last**, so nothing after it resets the
 *    material.
 * 6. `selectedColor(Color.Transparent)` — `ToggleType.Button`'s selected state
 *    defaults to the theme accent, so a press flashes an accent disc even though
 *    `isOn` is permanently false.
 *
 * ## `applyShadow` is off here, on purpose
 *
 * The documented default is `true`, and it takes priority over the component's
 * own `shadow` attribute. The shell already draws its own shadow; leaving the
 * carrier's on produces two offset shadows and, once the shell clips to a
 * radius, a crescent of the carrier's shadow survives inside the rim — which is
 * exactly the 「边缘光感异常」 artefact.
 *
 * ## `interactive` is off here, on purpose
 *
 * `interactive: true` adds press deformation and a light-sensing sweep. On a
 * *card* carrier it also made the material stop rendering entirely on the
 * reference device (HarmonyOS 7.0.0.105 / API 26). Press feedback belongs on the
 * shell (`.clickEffect()`), not on the material. The title-bar buttons, which are
 * genuinely buttons, do use it — see `Index.CircleAction`.
 */
@ComponentV2
export struct MaterialLayer {
  /** Must match the shell's corner radius or an inset rim appears. */
  @Param radius: number = 26;
  /**
   * Material thickness. 0 = 自适应 / 1 = 高 / 2 = 中 / 3 = 低, mirroring the
   * 沉浸光感挡位 setting. Resolved to an `ImmersiveStyle` by `styleFor()`.
   */
  @Param gear: number = 0;
  /**
   * Set false when the shell is a small surface (a chip, a 28 vp pill). A card
   * wants a visible edge; a 13 vp chip with a full-strength rim reads as a
   * sticker.
   */
  @Param enabledLayer: boolean = true;

  build() {
    Toggle({ type: ToggleType.Button, isOn: false })
      .width(LayoutPolicy.matchParent)
      .height(LayoutPolicy.matchParent)
      .borderRadius(this.radius)
      .backgroundColor(Color.Transparent)
      .selectedColor(Color.Transparent)
      .enabled(false)
      .focusable(false)
      .accessibilityLevel('no')
      .hitTestBehavior(HitTestMode.None)
      .attributeModifier(this.carrierModifier())
  }

  /**
   * Built per render, not inline in `build()`.
   *
   * An `attributeModifier` object literal written inline does not re-evaluate
   * when the theme, gear or accent changes: the closure body is not executed
   * during render, so reading state inside it never registers a dependency. A
   * method call *is* evaluated at render time, so the values captured here are
   * the current ones and a rebuild re-applies a correctly-configured carrier.
   */
  private carrierModifier(): AttributeModifier<ToggleAttribute> {
    const style: uiMaterial.ImmersiveStyle = MaterialLayer.styleFor(this.gear);
    const on: boolean = this.enabledLayer;
    return {
      applyNormalAttribute: (instance: ToggleAttribute): void => {
        if (!on) {
          return;
        }
        const options: uiMaterial.ImmersiveOptions = {
          style: style,
          applyShadow: false
        };
        instance.systemMaterial(new uiMaterial.ImmersiveMaterial(options));
      }
    };
  }

  /**
   * Gear → thickness.
   *
   * Must be a function, never a module-level constant. A module-level
   * `const STYLE = uiMaterial.ImmersiveStyle.THIN` dereferences `uiMaterial` at
   * *module load*; on an older SDK that is `undefined`, the `.THIN` access throws
   * outside any `try/catch`, and the whole module fails to load — the app crashes
   * on launch rather than merely losing the material. `uiMaterial` is API 26, so
   * this app can be installed on a device below it.
   */
  private static styleFor(gear: number): uiMaterial.ImmersiveStyle {
    switch (gear) {
      case 1:
        return uiMaterial.ImmersiveStyle.ULTRA_THICK;
      case 2:
        return uiMaterial.ImmersiveStyle.REGULAR;
      case 3:
        return uiMaterial.ImmersiveStyle.THIN;
      default:
        return uiMaterial.ImmersiveStyle.REGULAR;
    }
  }
}
