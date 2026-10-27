---
name: HarmonyOS Verification Loop
description: Verify HarmonyOS changes on the emulator end-to-end — static check, build, sign/install, launch, screenshot, UI tree, interaction, and hilog analysis. Use when a feature is implemented or a build/device error needs diagnosis.
---

# HarmonyOS Verification Loop

“Compiles” is not “works”. This skill is the evidence ladder for this repo.

## 1. Static check (fast)

```powershell
devecocli check arkts
# or only changed files:
devecocli check arkts entry/src/main/ets/pages/Index.ets
```

MCP alternative: `deveco.check` with the file list. Use it after a batch of
edits; do not run it after every keystroke.

Expected: `No errors` / only warnings you can explain. If it says
`please retry in N seconds`, the language service is still syncing; wait and
retry, or call `deveco.restart`.

## 2. Build

```powershell
devecocli build
```

Expected tail: `BUILD SUCCESSFUL` and an absolute artifact path, e.g.
`entry/build/default/outputs/default/entry-default-unsigned.hap`.

Rules:

- Fix the **first** error. Re-run; don’t fix five guesses at once.
- If the error is a missing module, run `devecocli build` again (it runs
  `ohpm install` + hvigor sync) or check `oh-package.json5`.
- If the build cache is suspect: `devecocli build clean` then build.
- Do not edit `entry/build/`, `.hvigor/`, or `oh_modules/`.

## 3. Device and signing

```powershell
. .\scripts\env.ps1   # OHOS_HDC_SERVER_PORT=18710, toolchain PATH
devecocli device list --format json
devecocli emulator list
devecocli emulator start puraxview --hdcport 15000
```

If `device list` is empty or hdc hangs:

1. **Check WSL2 port ownership first**: `Get-NetTCPConnection -LocalPort 8710
   -State Listen`; `wsl ss -ltnp | grep 8710`. If `wslrelay`/`sshd-sess` owns
   8710, keep `OHOS_HDC_SERVER_PORT=18710` and do not use 8710.
2. Check the emulator process and bridge:
   `Get-Process Emulator`; `Get-NetTCPConnection -LocalPort 15000`.
3. Kill stale hdc clients: `Get-Process hdc | Stop-Process -Force`.
4. Start the alternate server: `hdc -s 127.0.0.1:18710 start`;
   `hdc -s 127.0.0.1:18710 tconn 127.0.0.1:15000`;
   `hdc list targets -v`.
5. Read `%LOCALAPPDATA%\Huawei\Emulator\deployed\puraxview\Log\Emulator.log`
   for `Guest OS Boot Completed` / `hdc is not connected`.
6. Cold boot if the guest is stuck:
   `devecocli emulator stop puraxview`;
   `devecocli emulator start puraxview --hdcport 15000 --boot-mode coldboot`.

Signing:

- Official: `devecocli auth login --no-prompt` (user completes browser auth),
  then `devecocli signature generate --product default`.
- Offline/local emulator: `scripts\run.ps1` or
  `scripts\sign-and-install.ps1` (local debug chain in `signing/`; never ship
  it). `build-profile.json5` intentionally has no signingConfigs because
  hvigor expects DevEco-encrypted passwords.
- `install sign info inconsistent` → uninstall first:
  `scripts\run.ps1 -Uninstall` or `hdc uninstall com.hmprojects.hmstart`.

## 4. Install and launch

```powershell
devecocli run
# or, if already built:
devecocli run --skip-build
```

MCP alternative: `harmonyos.build_install_launch` after `parse_app_meta`.

Expected:

- `Smoke: PASS` (DevEco CLI runs a crash/blank check).
- `hdc shell aa dump -l` / MCP `app_state` shows
  `com.hmprojects.hmstart` in the foreground.

If `Smoke: FAIL_CRASH` or `FAIL_BLANK`, go to §7 before claiming success.

## 5. Screenshot

```powershell
New-Item -ItemType Directory -Force screenshots | Out-Null
devecocli ui screenshot --path screenshots\home.png
```

MCP alternative: `harmonyos.screenshot` (returns an inline image).

Then **read the PNG** and check:

- Expected title/first screen is visible; no blank white/black screen.
- Text is not clipped at the current width; no overlapping controls.
- Dark mode (if enabled) has readable contrast.
- Loading/error/empty states render correctly.

Screenshots are evidence, not decoration. Attach the path in your report.

## 6. UI tree and interaction

```powershell
devecocli ui layout --format json --mode simplified > ui-layout.json
devecocli ui window list --format json
devecocli ui click <x> <y>
devecocli ui click --id <nodeId>
devecocli ui text "hello"
devecocli ui swipe 100 800 100 300
```

MCP alternatives: `harmonyos.ui_dump`, `find_ui`, `tap_text`,
`tap_text_and_wait`, `input_text_and_wait`, `wait_for_ui`, `key_event`.

Rules:

- `ui layout` returns **on-screen nodes only**. Scroll the target into view
  before searching.
- Prefer `--id` over coordinates; IDs come from stable component `.id(...)`.
- For navigation, wait for the target text rather than sleeping.
- After each interaction, take a screenshot or re-dump the tree; don’t assume
  the tap worked.

## 7. Logs

```powershell
devecocli log --level E --from 2m --tail 200
devecocli log --crash --bundle-name com.hmprojects.hmstart
```

MCP alternatives: `harmonyos.logs_dump`, `logs_start`/`logs_stop`,
`wait_for_log` (use `Displayed` to wait for app start).

Analysis order:

1. **Fatal/crash**: `FaultLogger` / `devecocli log --crash`; read the top
   exception and the first app frame.
2. **Blank screen**: check `onWindowStageCreate`/`loadContent` errors, route
   registration, and the first page’s `aboutToAppear`.
3. **Install/sign**: `install sign info inconsistent`, `9568289`, or
   `INSTALL_FAILED_*`; see §3.
4. **ArkTS runtime**: `TypeError`, `undefined is not a function`, `Cannot read
   property`; map the line to the compiled source and fix the type.
5. **Network**: timeout/response code; check permission and URL.

Filter to your app: `--bundle-name com.hmprojects.hmstart`; use `%{public}s`
only for non-sensitive values.

## 8. Definition of done

A change is done only when all of these are true:

- [ ] `devecocli check arkts` on changed files: no errors.
- [ ] `devecocli build`: `BUILD SUCCESSFUL`.
- [ ] App installed and launched; foreground confirmed.
- [ ] Screenshot reviewed; target screen visible and sane.
- [ ] `ui layout` contains expected text/ids; key interaction tested.
- [ ] Error logs clean or explained; crash logs checked if restarted.
- [ ] Report includes commands, artifact path, screenshot path, and any
      device/toolchain limitation.

If the emulator is unavailable, stop at build + static check and say exactly
what is unverified. Do not invent a screenshot or claim UI success.

## References

- `references/troubleshooting.md` — error signatures and fixes.
