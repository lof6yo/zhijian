---
description: Build, install, and launch on the emulator, then confirm foreground
agent: harmonyos
---

Deploy the current app to the emulator:

1. `devecocli device list --format json` — if empty, start `puraxview` with
   `devecocli emulator start puraxview --hdcport 15000` and wait for hdc.
2. `devecocli run` (add `--uninstall` if signing changed).
3. Confirm the app is in the foreground with `devecocli device list` / MCP
   `app_state`.
4. If `Smoke: FAIL_CRASH` or `FAIL_BLANK`, read the crash log or the blank
   screenshot path and fix before reporting success.

Follow `AGENTS.md` §8 for signing. If signing is missing and the user has not
authorized a Huawei login, use the local emulator-only fallback and say so.
$ARGUMENTS
