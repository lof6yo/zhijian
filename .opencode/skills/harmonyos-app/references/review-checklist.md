# Review Checklist (paste into a PR)

## Build and API
- [ ] `devecocli check arkts` passes on changed files.
- [ ] `devecocli build` succeeds; no new warnings that matter.
- [ ] API 26 only; no deprecated/higher APIs.
- [ ] Imports are from `@kit.*`/`@ohos.*`; no deep SDK internals.

## State and lifecycle
- [ ] New UI uses V2 state; no V1/V2 mixing.
- [ ] `@Param` is not mutated; `@Event` used for outputs.
- [ ] No UI update after page disappearance.
- [ ] Heavy work off the UI thread; `@Concurrent` constraints respected.

## Navigation and pages
- [ ] New pages registered in `main_pages.json`.
- [ ] `Navigation`/`NavDestination`/`NavPathStack` used; no `router`.
- [ ] Params typed and validated; back stack works.

## UI and resources
- [ ] No hardcoded user-facing strings/colors/dimensions.
- [ ] Dark variant exists for every custom color.
- [ ] Responsive at phone and wide widths; no clipped text.
- [ ] Safe areas respected; tap targets ≥ 48vp.
- [ ] Lists lazy with stable keys; `@Reusable` where needed.
- [ ] Accessibility labels on icon-only controls.

## Data and security
- [ ] Secrets in Asset Store, not source/preferences/logs.
- [ ] SQL parameterized; file paths sandboxed.
- [ ] Permissions minimal, with `reason`/`usedScene`; denial handled.
- [ ] No signing material or `.env` in the diff.

## Verification
- [ ] App launches on the emulator; `app_state` confirms foreground.
- [ ] Screenshot reviewed (no blank/clipped/dark-mode issue).
- [ ] `ui layout` shows expected text/ids; key interaction tested.
- [ ] Error logs clean or explained; crash log checked if restarted.
- [ ] Artifact path and commands recorded in the PR description.
