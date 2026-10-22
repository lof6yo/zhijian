# ArkUI Patterns

## Navigation and page shell

- One root `Navigation` per page; `NavPathStack` owns the stack.
- `NavDestination` is the page container; set `.title()` and handle `.onReady`.
- Register pages in `main_pages.json`; only `@Entry` pages go there.
- Use `NavigationMode.Auto` for phone/tablet; test `Split` on a wide window.
- Back behavior: `NavPathStack.pop()`; system back is handled by `Navigation`.
- Pass typed params; do not use a global “current item” singleton.

```ts
this.pathStack.pushPath({ name: 'detail', param: id });
this.pathStack.pop();
this.pathStack.clear();
```

## Tabs

- Put `Tabs` inside the `Navigation` content; each `TabContent` is a page body.
- Use `barPosition(BarPosition.End)` for bottom tabs; keep 3–5 items.
- Lazy-load tab content with `TabContent().tabBar(...)` and per-tab view models.
- Keep tab state in the parent; don’t recreate stores on every switch.

## Lists

- `List` + `LazyForEach` for >20 items; stable `keyGenerator`.
- `cachedCount(3–5)`; `ListItem` height should be stable to avoid jumps.
- `@Reusable` for rows with images/complex subtrees.
- Pull-to-refresh: `Refresh` wrapping `List`; handle empty/error/loading states.
- Avoid nested vertical scrollables; use a single `List` with sections.

## Forms

- `TextInput`/`TextArea` with `@Local` value + `onChange`; validate on submit.
- Use `InputType.Email/PhoneNumber/Number` and `maxLength`.
- Show inline errors under the field; don’t rely on toast only.
- Disable submit while pending; prevent double submission.
- Keyboard: `Scroll` + `expandSafeArea`/`keyboardAvoidMode` so fields stay visible.

## Dialogs and feedback

- `promptAction.showToast` for transient success/failure.
- `AlertDialog` for destructive confirmation; label actions with verbs.
- `CustomDialogController` for complex forms; dismiss on back.
- Loading: `LoadingProgress` or a skeleton; avoid blocking the whole screen for
  a small request.

## Responsive layout

```ts
GridRow({ columns: { sm: 4, md: 8, lg: 12 }, gutter: { x: 12, y: 12 } }) {
  GridCol({ span: { sm: 4, md: 4, lg: 4 } }) { Card() }
  GridCol({ span: { sm: 4, md: 4, lg: 8 } }) { Content() }
}
```

- Test at 320–360vp (small phone), 400–480vp (large phone), and ≥600vp (tablet).
- Use `constraintSize({ maxWidth: 720 })` for reading columns on wide screens.
- Don’t scale text by screen width; use `fp` and let the system font scale.

## Dark mode

- Every custom color: `base/element/color.json` + `dark/element/color.json`.
- Prefer semantic names (`page_bg`, `text_primary`, `card_bg`) over raw colors.
- Check contrast for text/icons; don’t assume black-on-white.
- Test with system dark mode and with the app’s manual theme setting.

## Accessibility

- Icon-only buttons: `.accessibilityText('返回')`.
- Images that convey meaning: `.accessibilityDescription(...)`; decorative
  images: `.accessibilityLevel('no')`.
- Tap targets ≥ 48vp; spacing ≥ 8vp.
- Support font scaling; avoid fixed-height text rows.
- Focus order follows visual order; don’t trap focus in a dialog.

## Motion

- `animateTo({ duration: 220, curve: Curve.EaseOut }, () => { ... })`.
- Animate opacity/transform, not `width`/`height` in long lists.
- Respect reduced motion where available; keep essential feedback immediate.
- Use `TransitionEffect` for page/element enter/exit; avoid gratuitous motion.

## Performance

- `build()` should be pure composition; compute in view models.
- `LazyForEach` + `cachedCount`; avoid `ForEach` over hundreds of items.
- Images: request the display size; use `objectFit(ImageFit.Cover)`; cache.
- Avoid `@Prop` deep copies of large objects; use V2 `@Param` + `@ObservedV2`.
- Profile with ArkUI Inspector before optimizing; measure, don’t guess.
