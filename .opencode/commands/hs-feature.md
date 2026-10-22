---
description: Implement a feature end-to-end with verification
agent: harmonyos
---

Implement: **$ARGUMENTS**

Use the full loop:

1. Read `AGENTS.md` and the `harmonyos-app` skill. Inspect the relevant files.
2. For unfamiliar APIs, query `harmonyos-knowledge` first; check the local SDK
   `.d.ts` for exact signatures.
3. State a short plan (files, state/data flow, verification).
4. Implement typed ArkTS; V2 state; Navigation; resources + dark variants;
   least-privilege permissions.
5. `devecocli check arkts` → fix errors.
6. `devecocli build` → fix the first error until successful.
7. `devecocli run` (or MCP `build_install_launch`) → confirm foreground.
8. Screenshot + `ui layout`; test the key interaction.
9. Logs: no unexplained errors/crashes.
10. Report files, commands, artifact path, screenshot path, and limitations.

Do not stop at “it compiles”. If the emulator is unavailable, stop after step 6
and state exactly what remains unverified.
