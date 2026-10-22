# Troubleshooting

## Environment

### `devecocli` says “DevEco Studio installation not found”
Set `DEVECO_CLI_CLT_PATH` to the Command Line Tools root:

```powershell
$env:DEVECO_CLI_CLT_PATH = 'D:\deveco\command-line-tools'
```

This machine has CLT 26.0.0, not DevEco Studio. Do not set
`DEVECO_CLI_STUDIO_PATH` to a non-Studio directory.

### `devecocli` not found
It is installed globally at
`C:\Users\Huangly\AppData\Roaming\npm\devecocli.cmd`. Ensure
`%APPDATA%\npm` is on PATH, or reinstall:

```powershell
npm install -g @deveco/deveco-cli@1.3.6
```

### PowerShell blocks scripts
Use PowerShell 7 (`pwsh`) or:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
```

The MCP wrappers use `.cmd`, so they work regardless.

## Build

### `Invalid value of 'DEVECO_SDK_HOME'`
Set:

```powershell
$env:DEVECO_SDK_HOME = 'D:\deveco\command-line-tools\sdk'
```

### `Failed to resolve module` / missing `@ohos/*`
- Check `oh-package.json5` / `entry/oh-package.json5`.
- Run `devecocli build` (it runs `ohpm install`), or `ohpm install` in the
  project root.
- Do not import a package that is not declared.

### Build cache / stale output
```powershell
devecocli build clean
devecocli build
```
Do not delete `oh_modules` unless dependency resolution is corrupt; if you do,
rebuild immediately.

### ArkTS errors
- `arkts-no-any-unknown`: add a type; no `any`.
- `arkts-no-untyped-obj-literals`: declare a class/interface.
- `arkts-no-props-by-index`: use explicit fields or `Map`.
- `arkts-no-func-apply-bind`: call directly; pass a closure.
- `Page not found`: add to `main_pages.json`.
- `Resource not found`: add the key to `base`/`dark` or fix `$r`.

## Device / hdc

### `hdc list targets` is empty or hangs
1. **Check WSL2 port ownership first.** This machine uses WSL2 mirrored
   networking; `wslrelay.exe` / `sshd-sess` listens on `8710` (the hdc default),
   so hdc clients connect to the wrong service and hang.
   `Get-NetTCPConnection -LocalPort 8710 -State Listen`;
   `wsl ss -ltnp | grep 8710`.
2. Use a non-default server port everywhere:
   `$env:OHOS_HDC_SERVER_PORT = '18710'`.
   `scripts/env.ps1` and both MCP wrappers already set it.
3. Confirm the emulator is running:
   `Get-Process Emulator`; `Get-NetTCPConnection -LocalPort 15000`.
4. Kill stale hdc clients: `Get-Process hdc | Stop-Process -Force`.
5. Start the alternate server and re-add the target:
   `hdc -s 127.0.0.1:18710 start`;
   `hdc -s 127.0.0.1:18710 tconn 127.0.0.1:15000`;
   `hdc list targets -v`.
6. Check `Emulator.log` for `Guest OS Boot Completed`. If the guest is stuck,
   cold boot:
   `devecocli emulator stop puraxview`;
   `devecocli emulator start puraxview --hdcport 15000 --boot-mode coldboot`.
7. The current Emulator accepts hdc ports **10000–16555**; `5555` is rejected.
   The hdc server port (`18710`) and the device target (`127.0.0.1:15000`) are
   different.

### `hdc` server floods TIME_WAIT on 8710
The port is owned by WSL2 (`wslrelay`/`sshd-sess`), not hdc. Do not try to bind
8710; set `OHOS_HDC_SERVER_PORT=18710` and use `-s 127.0.0.1:18710` for manual
server commands. Killing hdc processes alone will not free 8710.

### Emulator starts but no window / no boot
- Check free disk/memory; the image needs several GB.
- Try `--boot-mode coldboot` or `--no-window` for diagnosis.
- Look at `C:\Users\Huangly\AppData\Local\Huawei\Emulator\deployed\puraxview\Log\Emulator.log`
  and `qemu.log`.

## Signing / install

### `install sign info inconsistent`
The installed app was signed with a different key. Uninstall first:

```powershell
hdc uninstall com.hmprojects.hmstart
# or
devecocli run --uninstall
```

Then install the new HAP. Keep one signing chain per bundle.

### `signature generate` says not logged in
`devecocli auth login --no-prompt`; the user completes browser auth. Then
`devecocli signature generate --product default`.

### No Huawei account / offline
Use the local debug chain:

```powershell
scripts\sign-and-install.ps1
```

This signs with `signing/hmstart.jks` + `signing/hmstart-debug.p7b`. It is for
the emulator only; never ship these materials.

### `9568289` / `INSTALL_FAILED_*`
- Check the HAP is signed and the profile bundle name matches
  `AppScope/app.json5`.
- Check the device API level ≥ `compatibleSdkVersion`.
- Uninstall the old app and retry.

## Runtime

### Blank screen
- `onWindowStageCreate` `loadContent` error? Check `devecocli log --level E`.
- Is the first page in `main_pages.json`?
- Does `aboutToAppear` throw before the first render?
- Is the root component height/width set (`100%`)?
- Check `Smoke: FAIL_BLANK` screenshot path from `devecocli run`.

### Crash on launch
`devecocli log --crash --bundle-name com.hmprojects.hmstart`; read the first
`Error`/`TypeError` and the top app frame. Common causes: undefined state,
missing permission, wrong `Want` param, or a removed resource.

### UI layout is empty / missing nodes
`ui layout` only returns on-screen nodes. Scroll the target into view
(`devecocli ui dircfling up` / `ui swipe`), then retry. Use `--mode full` for
diagnosis; `--mode simplified` for agent consumption.

### Tap does nothing
- The node may be under the keyboard; dismiss it (`key_event Back`).
- The text may be inside an image/custom drawable; use coordinates from
  `ui layout`.
- The target may be covered by a transparent overlay; inspect the full tree.

## MCP / OpenCode

### `opencode mcp list` says “No MCP servers configured”
The config is probably V1-shaped. OpenCode V2 requires:

```jsonc
{ "mcp": { "servers": { "name": { "type": "local", "command": [...] } } } }
```

Use `disabled: true`, not `enabled: false`. The DevEco CLI `init --mcp` writes
the V1 shape; keep `.opencode/opencode.json` in this repo as the source of truth.

### `deveco` MCP exits with “DevEco Studio installation not found”
The wrapper must set `DEVECO_CLI_CLT_PATH` (and `PROJECT_PATH`). Check
`scripts/mcp-deveco.cmd`; run it directly to see the error:

```powershell
scripts\mcp-deveco.cmd
```

It should print JSON-RPC only (no banner). If it prints an update notice, run
`devecocli update` or pin the version.

### `harmonyos` MCP exits / no tools
Run the wrapper directly:

```powershell
scripts\mcp-harmonyos.cmd
```

It needs `DEVECO_STUDIO_HOME`, `DEVECO_SDK_HOME`, and `hdc`/`hvigorw` on PATH.
Check `npm ls -g harmonyos-mcp`; reinstall with:

```powershell
npm install -g harmonyos-mcp@0.3.0
```

### `@deveco-codegenie/mcp` fails with “Failed to load config”
It requires a full DevEco Studio installation (not CLT-only). Use the `deveco`
+ `harmonyos` servers on this machine, or install DevEco Studio and set
`DEVECO_PATH` to its root.

### `devecocli serve lsp` in OpenCode V2
V2.0.32 does not expose a functional LSP runtime. Do not wire it; use
`deveco.check` (MCP) or `devecocli check arkts` (CLI).

### Knowledge MCP returns `Unsupported protocol version`
The server supports `2025-11-25`. OpenCode V2’s default `legacy` protocol
negotiates up to that; if a custom client fails, set the protocol version to
`2025-11-25`. No API key is required.
