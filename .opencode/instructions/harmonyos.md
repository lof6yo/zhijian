# HarmonyOS always-on rules

- This is **API 26**, Stage model, ArkTS/ArkUI. Never invent APIs; check
  `harmonyos-knowledge` or the local SDK `.d.ts` first.
- New UI uses **V2 state**: `@ComponentV2`, `@Local`, `@Param`, `@Event`,
  `@ObservedV2`, `@Trace`. No V1 decorators in new components.
- New navigation uses `Navigation` + `NavPathStack` + `NavDestination`. No
  `router.pushUrl`.
- No `any`, no untyped object literals, no index signatures, no
  `Function.apply/call/bind`, no `eval`.
- User-facing strings/colors/dimensions live in `resources`; add dark variants.
- Never read/print/commit `*.p12`, `*.jks`, `*.p7b`, `.ohos/`, or `signing/`.
- After edits: `devecocli check arkts` → `devecocli build` → deploy → screenshot
  or `ui layout` → logs. Do not claim success without device evidence.
- If the emulator is unavailable, report build/static-check results and state
  exactly what remains unverified.
