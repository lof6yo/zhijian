# AGENTS.md — HMStart / HarmonyOS NEXT

This file is the operating contract for every agent working in this repository.
It is loaded automatically by OpenCode V2. Keep it accurate; update it when the
toolchain or project layout changes.

## 1. Project snapshot

- **App**: `纸见` (display name; `app_name` + `EntryAbility_label`), bundle
  `com.hmprojects.hmstart` (kept — changing it invalidates the local debug
  signing profile), vendor `example`.
- **Platform**: HarmonyOS NEXT, Stage model, ArkTS + ArkUI, **API 26**.
- **Build**: Hvigor 6.26.4 via DevEco CLI 1.3.6; SDK `HarmonyOS 26.0.0 Release`
  (API 26) at `D:\deveco\command-line-tools\sdk`.
- **IDE**: none required. This machine has **Command Line Tools 26.0.0.821**,
  not DevEco Studio. Do not assume DevEco Studio-only paths or plugins.
- **Device**: HarmonyOS 7.0.0 emulator image `phone_all_x86`, instance
  `puraxview` (Pura X View, 1320×2232, 480 dpi). Preferred hdc port: `15000`.
  This machine runs WSL2 with mirrored networking, so WSL’s `sshd-sess`
  already owns the default hdc port `8710`. **Always set
  `OHOS_HDC_SERVER_PORT=18710`** before using `hdc`/DevEco CLI/MCP; otherwise
  hdc hangs or reports no devices. The MCP wrappers and `scripts/env.ps1`
  already do this.
- **Entry module**: `entry` (HAP). `AppScope` holds app-level config/resources.
- **Entry page**: `entry/src/main/ets/pages/Index.ets`, registered in
  `entry/src/main/resources/base/profile/main_pages.json`.
- **UIAbility**: `entry/src/main/ets/entryability/EntryAbility.ets`.
- **Language**: UI copy is Chinese; code identifiers, comments, and commit
  messages follow the existing file. Keep user-visible strings in resources.

## 2. Golden rules

1. **Never invent HarmonyOS APIs.** Before using an unfamiliar API, search the
   official docs with MCP `harmonyos-knowledge` (`searchDocuments` →
   `getDocumentsById`) or `devecocli docs search/read`. Check the local SDK
   `.d.ts` when the docs are ambiguous.
2. **API 26 only.** Do not use APIs marked deprecated or higher than 26. Do not
   lower `targetSdkVersion`/`compatibleSdkVersion` without an explicit request.
3. **ArkTS strict mode.** No `any`, no untyped object literals, no index
   signatures, no prototype tricks, no `eval`, no `Function.apply/call/bind`,
   no `Object.defineProperty`. Give every class/interface/field a type.
4. **State management V2 for new code.** Use `@ComponentV2`, `@Local`,
   `@Param`, `@Event`, `@ObservedV2`, `@Trace`, `@Provider`, `@Consumer`.
   Do not mix V1 decorators (`@State`, `@Prop`, `@Link`, `@Observed`,
   `@ObjectLink`) into new V2 components. `Index.ets` has been migrated to
   `@ComponentV2`/`@Local`; treat V1 as legacy only.
5. **Navigation, not router.** New pages use `Navigation` + `NavPathStack` +
   `NavDestination`. Do not add `router.pushUrl` calls.
6. **Resources, not literals.** Colors, strings, dimensions, and icons come from
   `resources/base/element/*.json` or `$r('app.*')`/`$r('sys.*')`. Add a dark
   variant under `resources/dark/` for every custom color.
7. **Least privilege.** Declare permissions in `module.json5` with `reason` and
   `usedScene`. Request runtime permissions with `abilityAccessCtrl` at the
   moment of use. Never put secrets/API keys in source; use Asset Store Kit.
8. **Verify before claiming done.** A change is not done until: static check
   passes, build succeeds, the app launches on the emulator, and the target UI
   is verified by screenshot or `ui_dump`. If the device is unavailable, say so
   explicitly and report the build/check result only.
9. **Do not hand-edit generated output** under `entry/build/`, `.hvigor/`, or
   `oh_modules/`. Fix source and rebuild.
10. **Do not read, print, or commit signing secrets** (`*.p12`, `*.jks`,
    `*.p7b`, `.ohos/`, `signing/`). The agent may reference paths in config but
    must not dump their contents.

## 3. Standard workflow

Use this loop for every feature or bug fix:

1. **Recon** — read the relevant page/service, `AGENTS.md`, and the target
   resource files. For unfamiliar APIs, query the knowledge MCP first.
2. **Plan** — name the files to change, the state/data flow, and the verification
   steps. For a UI change, state the layout at phone and tablet widths.
3. **Implement** — small, typed ArkTS changes. Keep business logic out of
   `build()`; put it in view models/services.
4. **Static check** — run `devecocli check arkts` on changed `.ets` files
   (preferred; the `deveco` MCP is disabled on this CLT-only machine). Fix all
   errors before building.
5. **Build** — `devecocli build` (or MCP `harmonyos.build`). Read the first
   error, fix it, repeat. Do not paste the whole build log.
6. **Run** — `devecocli run` (or MCP `harmonyos.build_install_launch`). If
   signing is missing, see §8.
7. **Verify UI** — `devecocli ui screenshot` / MCP `harmonyos.screenshot`, then
   `devecocli ui layout` / MCP `harmonyos.ui_dump` to confirm the target text
   and interactive nodes. Use `find_ui`/`tap_text` for interactions.
8. **Logs** — `devecocli log --level E --from 2m --tail 200` or MCP
   `harmonyos.logs_dump`. Fix crashes/blank screens before stopping.
9. **Report** — state what changed, the commands run, the artifact path, the
   device/screenshot evidence, and any remaining limitation.

For a pure question ("how does X work?"), skip steps 4–8 unless the answer
depends on running code.

## 4. Toolchain and commands

Set the environment once per shell:

```powershell
$env:DEVECO_CLI_CLT_PATH = 'D:\deveco\command-line-tools'
$env:DEVECO_SDK_HOME     = 'D:\deveco\command-line-tools\sdk'
$env:DEVECO_STUDIO_HOME  = 'D:\deveco\command-line-tools'
# WSL2 mirrored networking owns 8710; use 18710 for hdc/DevEco CLI/MCP.
$env:OHOS_HDC_SERVER_PORT = '18710'
# Optional: put hvigorw/ohpm/hdc/emulator on PATH
$env:PATH = "D:\deveco\command-line-tools\bin;D:\deveco\command-line-tools\sdk\default\openharmony\toolchains;D:\deveco\command-line-tools\emulator;$env:PATH"
```

| Goal | Command |
|---|---|
| Scaffold a new project | `devecocli create --app-name MyApp --api-level 26` |
| Install deps / sync | `devecocli build` (runs `ohpm install` + hvigor sync) |
| Build HAP | `devecocli build` |
| Build whole product (.app) | `devecocli build --product default` |
| Clean | `devecocli build clean` |
| ArkTS static check | `devecocli check arkts [files...]` |
| Lint | `devecocli check lint [path] --format json` |
| Install + launch | `devecocli run` |
| Device list | `devecocli device list --format json` |
| Emulator list/start/stop | `devecocli emulator list` / `start puraxview --hdcport 15000` / `stop puraxview` |
| Screenshot | `devecocli ui screenshot --path screenshots\shot.png` |
| UI tree | `devecocli ui layout --format json --mode simplified` |
| Click / text / swipe | `devecocli ui click ...`, `devecocli ui text ...`, `devecocli ui swipe ...` |
| Logs / crash | `devecocli log --level E --from 2m --tail 200` / `devecocli log --crash` |
| Docs search/read | `devecocli docs search <kw>` / `devecocli docs read <id>` |
| Signing | `devecocli auth login --no-prompt` → `devecocli signature generate` |
| Local debug deploy | `scripts\run.ps1` (build + local sign + install + launch) |
| Environment doctor | `scripts\doctor.ps1` |

App icon (`scripts/gen-icon.ps1`): redraws the layered icon and the start icon
with GDI+. Run it only when the mark should change, then rebuild. HarmonyOS
rules baked into the script: foreground and background are both **1024×1024**,
the background is a **pure solid colour** (no gradient, no graphics, no
transparency), nothing self-clips a rounded corner, nothing adds inner padding,
and the mark is scaled about the canvas centre so its half-diagonal stays inside
the launcher mask circle. The **entry** copy of `foreground/background.png`
wins over `AppScope`, so the script writes both — editing only one leaves the
launcher showing the old placeholder.

Direct fallbacks (only when DevEco CLI is unavailable):

```powershell
D:\deveco\command-line-tools\bin\hvigorw.bat --mode module -p module=entry@default -p product=default assembleHap --no-daemon
D:\deveco\command-line-tools\sdk\default\openharmony\toolchains\hdc.exe list targets
D:\deveco\command-line-tools\sdk\default\openharmony\toolchains\hdc.exe -t 127.0.0.1:15000 install -r <signed.hap>
```

Build output: `entry/build/default/outputs/default/entry-default-unsigned.hap`
(unsigned unless `signingConfigs` is configured).

## 5. MCP routing

MCP servers are configured in `.opencode/opencode.json` (V2 schema:
`mcp.servers`). Use them as follows:

| Server | Tools | Use for |
|---|---|---|
| `harmonyos` | 33 tools (see below) | Emulator lifecycle, build/install/launch, UI inspection/automation, logs, file pull. |
| `harmonyos-knowledge` | `searchDocuments`, `getDocumentsById` | Official HarmonyOS docs/API/guide/best-practice lookup. No API key. Use before writing unfamiliar APIs. |
| `deveco` (disabled) | `check`, `restart` | Optional. The official `devecocli serve mcp` check needs a full DevEco Studio LSP; on this CLT-only machine it never finishes project initialization. Enable only after installing DevEco Studio 6.1+. Otherwise use `devecocli check arkts` (CLI). |

Key `harmonyos` tools:

- `session_show_defaults` — call first; shows resolved project/toolchain/device.
- `session_set_defaults` — seed the server session once:
  `{ projectDir: "D:\\HMProjects\\HMStart", module: "entry",
  bundleName: "com.hmprojects.hmstart", abilityName: "EntryAbility",
  deviceSn: "127.0.0.1:15000", buildMode: "debug" }`. Then most tools accept
  empty args.
- `parse_app_meta` — reads `AppScope/app.json5` + `module.json5` and seeds
  defaults (bundle/module/ability).
- `emu_list` / `emu_start` / `emu_stop` — emulator lifecycle. `emu_start` waits
  for hdc and sets the device.
- `device_list` / `app_state` — cheap device/foreground checks.
- `build` / `install` / `launch` / `build_install_launch` — build/deploy loop.
- `screenshot` / `ui_dump` / `find_ui` / `tap_text` / `tap_text_and_wait` /
  `wait_for_ui` / `input_text` / `key_event` — UI verification.
- `logs_dump` / `logs_start` / `logs_stop` / `wait_for_log` — hilog.
- `pull_file` — pull DB/log/screenshot files from the device.

Usage rules:

- Prefer MCP for **structured actions** (build/install/launch/UI/logs) and the
  CLI for **human-facing inspection** (docs, diff, one-off commands).
- MCP `harmonyos` builds an unsigned HAP unless the project has a valid
  `signingConfigs`. If install fails with a signing error, use §8.
- Do not run `devecocli serve lsp` in OpenCode V2.0.32: V2 has no functional
  LSP runtime. Use `devecocli check arkts` (fast, works with CLT) instead. The
  `deveco` MCP is disabled for the same reason; enable it only with a full
  DevEco Studio installation.
- Global plugin MCPs `context7` and `gh_grep` are also available: use
  `gh_grep` for real-world code patterns and `context7` for third-party library
  docs. They are **not** a substitute for HarmonyOS knowledge MCP.

## 6. Architecture and code layout

Current single-HAP layout:

```text
entry/src/main/ets/
├── entryability/        # UIAbility lifecycle only
├── pages/               # Index (HDS shell: 3 tabs, title bar actions),
│                        # ReaderPage / TrashPage / WebDavPage (NavDestination)
├── components/          # NoteCard, CardSurface, MaterialLayer (沉浸光感
│                        # Toggle carrier), FormulaWeb (KaTeX 块级公式)
├── markdown/            # 自研 Markdown 引擎：MdTypes (AST) / MdParser /
│                        # CodeHighlight / MathLite / MdView (原生 ArkUI 渲染)
├── models/              # Note (V2 @ObservedV2/@Trace)
├── services/            # NoteStore (files), Frontmatter (YAML),
│                        # WebDav (RCP client), SyncEngine (three-way merge),
│                        # Credentials (Asset Store), SettingsStore (prefs)
└── common/              # WindowService, Palette

entry/src/main/resources/rawfile/render/
├── katex.html           # 唯一的 Web 渲染页：块级公式
└── vendor/              # katex.min.js + katex.min.css + KaTeX_*.woff2（离线）
```

**包体只有两件事：应用代码（`ets/modules.abc` ≈ 524 KB，debug 另带
`sourceMaps.map`/`symbolMap.map`）和这一套 KaTeX（≈ 558 KB）。**
曾经这里有 Mermaid（5.4 MB）与 ECharts（1.1 MB），以及一个 Vite 构建的 Crepe
编辑器（2.7 MB），三者加起来占 HAP 的 93%——而**没有一条 UI 路径能走到它们**：
`MdView` 把图块画成「渲染未接入」占位卡片，`EditorPage` 也没有任何 `pushPath`
入口。删掉之后 release HAP 从 10.5 MB 降到 **1,345 KB**。要加回图表，先读 §6
「图表为什么不在包里」。

### WebDAV sync

Sync is **native WebDAV over RCP**, not a third-party SDK, and the design
decisions below are all load-bearing — each one was chosen after an alternative
failed on the device.

- **Transport is `@kit.RemoteCommunicationKit` (RCP), not `@ohos.net.http`.**
  `http.RequestMethod` is a closed enum with no `PROPFIND`/`MKCOL`/`MOVE`, so
  WebDAV cannot be expressed with it at all. `rcp.HttpMethod` accepts arbitrary
  verbs, and `security.serverAuthentication` does RFC 7617 basic auth natively.
- **`dns` and `proxy` live on `requestConfiguration` (`rcp.Configuration`), not
  on `SessionConfiguration`.** A `StaticDnsRule` is keyed on host **and port**, so
  the port must come from the URL, not a hardcoded 443. `WebProxy.createTunnel`
  must be `'always'` for HTTPS — anything less sends an absolute-URI GET to the
  proxy and TLS never happens.
- **A request is retried on a 5xx or a transport throw (3 attempts).** Behind a
  CONNECT proxy the tunnel intermittently dies during setup and RCP reports
  `500 Connection established` — the proxy's tunnel status, not the origin's
  answer. `curl` against the same URL succeeds on every attempt. Every verb used
  here is idempotent for the same body, so a retry is safe.
- **Sync identity is the frontmatter `id`, never the filename.** Every device
  names an untouched note 无标题, so pairing by name would merge unrelated notes.
- **Three-way merge against a persisted baseline, not timestamp guessing.**
  `settings.syncBase` holds one line per note (`id \t updatedAt \t relPath`;
  flat text because ArkTS forbids index signatures). Per id: only-local-changed
  → upload; only-remote-changed → apply; both changed → conflict copy
  `<title> (冲突 HHmm).md` with a freshly minted id, so **both** bodies survive.
- **The baseline records what the server is *confirmed* to hold.** Only an
  operation that actually reached the server may write a row. A failed PUT
  records nothing, so the next run still sees "local changed, remote unchanged"
  and retries. Writing an unconfirmed row is the data-loss bug: the baseline then
  claims the server already has the new body, the next run reads the old remote
  file, calls it "the remote changed", and overwrites the newer local note.
  Verified the hard way on the emulator — it did exactly that.
- **A failed remote read aborts the whole run.** A partial listing cannot drive
  a merge: an id that failed to load is *absent* from the index, so the merge
  concludes "never uploaded" or "deleted remotely" and destroys data.
- **`updatedAt` is monotonic: a remote copy older than the local one never
  wins.** A stale sibling, a restore, or a rename leftover all present as "remote
  changed" with an older timestamp. Local is then re-uploaded instead.
- **One id must own exactly one remote path.** A note renamed in the editor
  after upload otherwise leaves its old file behind, and the id then names two
  bodies that flip on every sync. Any id this run pushed is authoritative: every
  *other* remote file carrying that id is deleted, re-listed after the run
  because the new path was never in the pre-run listing. Cleanup only fires when
  the local filename provably exists remotely — a merely-downloaded note keeps
  the server's filename locally, and deleting "everything but the local name"
  would remove the file it was just read from.
- **Remote paths and local paths are different dialects.** `WebDavClient` reports
  paths relative to the base URL (`zhijian/a.md`); `Note.relPath` is a bare
  filename (`a.md`). `SyncEngine.localRel()` normalises at parse time and
  prefixes are re-added only when a request is built. Comparing the two directly
  made every note look renamed on every run, so the vault was re-uploaded in full
  each sync.
- **XML is parsed by splitting on `<...response` boundaries with
  prefix-tolerant regexes.** `convertxml` returns untyped `object` (banned), and
  `XmlPullParser`'s `tagValueCallbackFunction` only fires for elements that have
  text, so `<D:collection/>` would be invisible.
- **`NoteStore.importFromSync()` / `overwriteFromSync()` exist instead of reusing
  `saveNote()`.** `saveNote()` renames the file to match the H1, so every pull
  would immediately re-upload under a new name.
- **The conflict mark lives in the body's H1, not just the filename.** The list
  renders `note.title`, and `reload()` re-derives it from the H1 — stamping only
  the filename left two cards reading the same title with no way to tell which
  one sync produced.
- **Deletions propagate through the baseline row, which is also the tombstone.**
  See *Deletion propagation* below — a note missing on one side is trashed on
  the other (local 回收站 / remote `zhijian/.trash`), never re-uploaded blindly.
- **Remote folder is a dedicated `zhijian/`**, auto-created with `MKCOL` (405 =
  already there), so the user's existing `Obsidian/` is untouched.
- **The password lives in Asset Store Kit** (`@kit.AssetStoreKit`, alias
  `zhijian.webdav`). URL / username / DNS pin / proxy are preferences. The field
  is never prefilled: a stored password shows as 「已保存，留空则不修改」 and a
  blank submit means "keep the existing one". Never put a password in source, in
  preferences, or in a commit.
- **`DavConfig.dnsHost`/`dnsIp` and `DavConfig.proxyUrl` are product features,
  not test scaffolding.** The emulator has no working DNS (its `resolv.conf`
  points at unreachable servers and `hdc` cannot fix it: `target mount` needs
  debug mode, `shell` is uid 2000) and no direct egress (the host reaches the
  server only through a corporate CONNECT proxy). Real devices behind split DNS
  or a corporate proxy need the same two escape hatches.

### Deletion propagation

Deleting a note is a *decision*, and it now propagates in both directions. The
hard part is that "missing on one side" is ambiguous — it means either *never
existed there* or *was deleted there*. Getting that wrong either resurrects a
deleted note or destroys a live one, so the baseline row doubles as the
tombstone: it already records "the server held this id at the end of the last
run".

| local | remote | baseline | verdict |
|---|---|---|---|
| yes | yes | — | three-way merge (§ above) |
| yes | no | yes | deleted remotely → local file → 回收站 |
| no | yes | yes | deleted locally → server file → `zhijian/.trash` |
| yes | no | no | never uploaded → upload |
| no | yes | no | new on another device → download |

- **A note missing remotely with a baseline row moves to the local 回收站**, not
  the void: `NoteStore.deleteNote()` renames it into `.trash` with a `<millis>-`
  prefix, and `purgeExpiredTrash(30)` already owns the retention. That is why
  propagating deletions is safe at all — it is reversible for 30 days.
- **A note missing locally with a baseline row has its server copy MOVEd into
  `zhijian/.trash/<millis>-<name>.md`.** `WebDavClient.moveTo` sends `MOVE` with
  an absolute `Destination` header and falls back to `GET` → `PUT` → `DELETE` if
  the server refuses (405/501); the fallback is exactly equivalent for one file.
  `.trash` is created with `MKCOL` on first use.
- **The timestamp prefix is the retention clock, not `getlastmodified`.** A
  `MOVE` may preserve the note's own mtime, so a note deleted today but last
  edited 40 days ago would be swept immediately. `purgeRemoteTrash()` parses the
  leading `<millis>-` (same rule as `NoteStore.trashTimeOf`) and falls back to
  `entry.modifiedAt` only when the name has no stamp.
- **`.trash` sits inside `zhijian/`** so the vault stays one folder. Nothing is
  re-imported from it because every listing runs at `Depth: 1` and skips
  directory entries.
- **`trashSeq` disambiguates same-millisecond trash entries.** Two notes deleted in
  one run would otherwise both target `zhijian/.trash/<same millis>-…`; the
  second `MOVE` would overwrite the first, i.e. data loss in the folder that
  exists to prevent it. (Named `trashSeq`, not `archiveSeq`: 笔记的「归档」是
  另一个概念，同一个词不能同时指「移入回收站」。)
- **A refused delete keeps its baseline row; only a confirmed one drops it.**
  `trashRemote()` returns true only when *every* path for that id was trashed,
  and `deleteNote()` now returns whether the file actually reached `.trash`. A
  failed `MOVE` that also lost its row would make the next run see a remote file
  with no baseline, call it "new from another device", and *download the note the
  user just deleted*. `buildBase()` is therefore a carry-forward: it starts from
  the previous rows and applies this run's outcomes, instead of rebuilding from
  `confirmed` alone.
- **The baseline is scoped to the server it describes** — `syncBaseScope` holds
  `<baseUrl>\t<username>`, written with the baseline and checked before reading
  it. Point the app at a different URL and the old rows would claim the new
  server had deleted the entire vault. An unrecognised scope means "no
  baseline", which re-uploads instead of trashing.
- **A note that merely lost its `id:` line is not a deletion.** Identity is
  recovered from the *baseline path* before the merge runs: `baseByPath` maps the
  path the baseline last recorded to its id, so a remote file that kept its name
  but lost its frontmatter id is adopted as that note and merges normally. The
  mirror case is handled in the remote-only pass: a local file still sitting at
  the baseline path under a filename-derived id gets its id restored from the
  baseline. Deciding by id alone would trash a live note, import a duplicate, or
  archive the server copy of a note that is still on this device.
- **Never repair frontmatter by overwriting the body.** The earlier design
  re-uploaded the local note when the remote file lost its id, which silently
  rolled the remote text back to whatever this device held. Recovering the
  identity and merging is the only safe repair.
- **`deleteNote()` returns `boolean`.** Callers that ignore it are fine (the
  editor's 删除 just wants the note gone from the list); sync uses it to decide
  whether the deletion is confirmed.

The native shell owns file storage, navigation, search, tags, rendering and
editing. All notes are flat in `notes/`. Markdown text is the source of truth:
`ReaderPage` parses it, writes it back through `NoteStore`, and debounces 500 ms.

**ArkWeb is no longer the editor.** The Crepe/Milkdown surface
(`EditorPage` + `editor-web/` + `rawfile/editor/`, 2.7 MB) was removed: nothing
could reach it — `ReaderPage` owns both reading and editing, and no `pushPath`
ever named `'editor'`. `EditorPage` survives only as history in git.

### Reading vs editing: one page, no mode switch

`ReaderPage` is both the reader and the editor. **There is no 阅读/编辑 toggle.**
A note opens rendered; tapping the body starts editing in place. That is the whole
interaction.

Two editing experiences, both reachable from the same tap (设置 › 编辑体验):

- **分块 (default).** Tapping a block edits *that block*: source on top, its
  rendered result below (`LiveBlockEditor`). This is the default because it keeps
  the reading and writing contexts identical — the rest of the document stays
  typeset while you work on one paragraph.
- **简单.** Tapping anywhere opens **one full-screen Markdown field** holding the
  whole note (`WholeDocEditor`) — a notepad. No blocks, no preview panel; 完成
  returns to the rendered view. The caret lands at the block that was tapped, so
  "点哪儿写哪儿" still holds. It deliberately borrows the *reading* view's
  typography — same font, size, line height, 20 vp side inset and background — so
  entering it does not feel like switching applications. A monospaced, zero-inset
  field here reads as a different product and was rejected on device.

**格式按钮条 is off by default** (设置 › 格式按钮条). It is the closed loop for people
who do not know Markdown — `标题 / 粗体 / 斜体 / 列表 / 待办 / 引用 / 表格 / 代码`
turn structure into something tappable instead of documented — but a row of buttons
is also interference when you only want to fix a word. `MarkdownEdits` holds the
pure text transforms so both editors produce byte-identical results for the same
button.

- **Why no mode.** "打开就能记" is the point of a notes app. A 编辑 gate makes the
  user declare intent before changing one character, and read-only browsing is not a
  state that deserves entering. This is the Typora model.
- **Why source, not a rich-text caret model.** Markdown's source *is* the
  specification — `##`, `-`, `**` are what the user types. Hiding them means the
  user cannot predict what the next keystroke does.
- **The block's line range comes from `MdParser.srcRangeOf(blocks, i, totalLines)`.**
  `totalLines` is **required for the last block**: it has no "next block" to borrow
  an end from, so without it a multi-line final block is truncated to its first line
  and recommitting splits it in two. Replacement always consumes the blank lines
  between blocks and puts one back.
- **A tap on body text is consumed by the `Span`.** Every inline `Span` carries
  `onClick` (links must be tappable), and a child click does not reach the parent
  container. `.hitTestBehavior(HitTestMode.None)` on a custom component does **not**
  fix it. The only reliable route is a flag: `MdBlockView.tapToEdit` → every
  `MdInlineText` branches inside its own `onClick` and calls `onBlockTap` instead of
  `onLink`. The wrapper's own `onClick` catches areas with no spans (code, tables,
  dividers).
- **Never overlay a `height('100%')` click-catcher on a content-sized block.** A
  percentage height inside a content-driven stack resolves against the *available*
  height, so each block inflates to a screenful and pushes the rest out of the
  viewport. Same trap as the material carrier — see `.background(builder)` above.
- **`ForEach` keys must include a render epoch.** `MdBlock.id` is the parse index, so
  checking a task or changing a word leaves it unchanged; an unchanged key means the
  framework reuses the old node and the screen keeps the previous content (measured:
  the file already said `- [x]` while the circle still rendered empty). Every
  mutation of the body bumps `ReaderPage.epoch` and folds it into the key.
- **`LiveBlockEditor` re-seeds its draft through `@Monitor('initialSource')`, not
  `aboutToAppear`.** Switching from "editing block N" to "append at the end" reuses
  the same component instance (same structural position), so `aboutToAppear` never
  runs again and the box would still hold the previous block's source.
- **"动过没有" is `value !== initialSource`, not "onChange fired".** Mounting the
  text box fires `onChange` once with the seeded text; treating that as an edit
  defeated the discard rule and left an empty 无标题 in the list.
- **Deleting a block asks first.** It only edits the body, so it is not recoverable
  from 回收站 — a one-tap irreversible delete of a whole paragraph is the easiest way
  to lose real content on this page.
- **`+` opens this same page** (`ReaderParam.created: true`), not the ArkWeb editor:
  a new note should start being written immediately. Leaving a just-created note
  untouched purges it, so a mis-tap does not leave a 无标题 husk.
- **Only a note created from `+` may auto-enter editing.** The rule briefly also
  fired for any note whose body was blank or still just `# 无标题`, which meant a
  list full of untitled notes opened straight into an editor — the reader stopped
  being a reader. Existing notes now always open rendered; the keyboard only appears
  when the user taps the body.
- **设置 is grouped by purpose**, in this order: 外观 / 阅读与编辑 / 同步与备份 /
  回收站 / 关于. Each group is a `SectionLabel` plus its cards; keep a new row inside
  the group it belongs to rather than appending it to the end of the list.
- **卡片圆角 belongs to 外观, not to 阅读与编辑.** It decides what a card *looks
  like*, and the settings page's own group cards are drawn with it.
- **设置 group cards are the same kind of card as a 笔记卡片.** They share
  `components/CardSurface.ets` (沉浸光感 + 半透明遮罩), the same 卡片圆角 value and
  the same shadow on the backdrop. The settings page used to paint a flat
  translucent fill with a hard-coded 20 vp radius, which read as another app's
  controls. `NoteCard` and the settings rows must keep using one implementation —
  two copies of the surface would drift.
- **Slider settings are one row each** — label, slider, value side by side. They
  used to be two lines (title + value) plus a full-width slider below, and three
  of them ate most of the settings page.
- **标签页 has sorting and filtering.** Sort by 名称 / 数量, each with an
  ascending/descending toggle shown as an arrow on the active chip (tapping the
  active chip flips the direction, tapping the other switches the key); filter by
  全部 / 在用, where 在用 hides the tags that exist only in the 名录 and are
  used by no note (`store.countTag(tag) > 0`).
  The chips use the **same** capsule treatment as the notes page's 筛选条/排序条
  (`TagChipGroup` mirrors `ChipGroup`): same 34 vp shell, same 28 vp pills, same
  material. Two pages showing the same control in two different styles is what
  makes an app look assembled rather than designed. The tag cards themselves
  carry the same `SIDE_INSET` as the notes grid — a full-bleed row reads as a
  stretched banner, not a card.
- **A `@Builder` call returns `void`, so you cannot chain `.onClick` onto it.**
  Wrap the builder in a `Row` and put the handler on the wrapper.
- **合并到同一张卡片里的行，各自要能点。** 「同步与备份」把 WebDAV 同步与
  导入/导出合成一张卡片（中间一条分隔线），两行的点击区仍然分开。
- **标签页有搜索、新建与长按菜单。** 标题栏两个按钮与笔记页同款（搜索 / 新建）。
  长按标签卡片弹出 **修改 / 删除**。删除只把标签从笔记里去掉，**笔记本身
  不动**，所以确认框里必须写明「这些笔记不会被删除」。
- **「置顶」已整体移除，两处都是。** 笔记置顶（frontmatter `pinned`）与标签置顶
  （`TagStore.pinned`）一起拆掉：同一个词在两处含义不同，是这页最容易让人绕晕的
  地方；留一半、拆一半只会更糟。`TagStore` 里保留 `KEY_PINNED_RETIRED` 这个**未读**
  常量，因为装过的机器上偏好文件里仍有 `pinnedTags`，而 Preferences 从不回收键——
  留着名字是为了让下一个人搜到它时知道它已停用，而不是认领它去存别的东西。
  `FrontmatterCodec.build()` 会整块重写 frontmatter，所以旧文件里的 `pinned:` 会在
  它下次被写入时自然消失，不需要迁移脚本。
- **标签有一部分状态不在 frontmatter 里。** 「有哪些标签」能从笔记推出来，但
  **刚创建、还没有笔记使用的标签**推不出来，所以另存一份标签名录
  （`services/TagStore.ets`，换行分隔的纯文本）。
  标签的增删改仍然作用在笔记的 frontmatter 上（`NoteStore.renameTag` /
  `NoteStore.removeTag`）。
- **界面状态不要靠跨单例的观察。** 普通单例的字段改了不会触发重绘；把它改成
  `@ObservedV2` + `@Trace` 之后，实测**跨单例读 `@Trace` 的观察链依然不触发
  刷新**（实测：普通单例与 `@ObservedV2` 单例都试过，界面毫无反应）。可靠做法是本工程一直在用的
  `@Local` 快照：把单例里的值拷进 `@Local`，改完显式刷新快照。
  `Index.tagsSnapshot` / `Index.notesSnapshot` 就是这么做的——新建标签、改名、删除
  之后都必须调 `refreshList()`，否则列表不更新。
- **搜索词是跨页签共享的**（标题栏只有一套搜索框），作用在当前页签上；切页签时
  清空，免得把笔记页的搜索词带到标签页。

### 自动同步与下拉同步

- **自动同步只在前台做。** 机制是「30 秒心跳 + 一条策略」：心跳只判断「该不该同步」，
  本身不发请求。心跳由 `EntryAbility.onForeground` / `onBackground` 驱动——后台同步要
  申请后台任务权限，而且一个本地优先的应用**不应该在用户不知情时把内容发到服务器**。
- **自动同步在四种情况下不做**：没配 WebDAV；上一次同步还没结束（同步是串行的，重叠会
  互相踩基线）；**详情页开着**（阅读器里可能有未提交的草稿，同步会改文件，草稿写回
  就把同步下来的内容盖掉）；距上次尝试不足间隔（连续失败按 2 的幂退避，最多 4 倍）。
- **手动下拉同步走同一条路径**，只是跳过间隔与退避判断——用户明确要求了。
- **手势进行中 ArkUI 不重绘组件树。** 实测：手指还按着时把 `@Local` 改掉，界面纹丝
  不动，松手后才一次性更新。所以「环随拉动进度填满」**不能**靠 `@Local` + `ForEach`
  做出来，只能直接往 Canvas 上画（画完自动在下一帧重绘，不需要 `flush`）。
- **`WaterFlow` 没有 `edgeEffect`**，平台不给它回弹，`Refresh` 的下拉手势与「把列表
  整体下移」的弹性位移在它身上都不发生。笔记网格因此改用 `List` + `lanes(2)`——
  平台原生下拉刷新的标准结构。代价：泳道**按列填**（左列 0,2,4…），而 `WaterFlow`
  是按行填；泳道之间没有横向间隙，用外边距手搓出 12 vp 的缝（用 margin 不用 padding，
  padding 会把卡片的文字宽度也缩掉，长标题多折一行）。
- **环要做成浮层，不要放进 `Refresh` 的刷新区。** 刷新区的高度由平台按拉动距离给，
  一旦平台没认下这次下拉，它的高度就是 0，里面的东西全被裁掉——环会凭空消失。

### 笔记卡片的左右滑动（邮箱式）

`components/NoteCard.ets` 自己实现了左右滑动，**没有**用 `ListItem.swipeAction`
（`WaterFlow` 的 `FlowItem` 没有这个属性，而为了它把网格换成 `List` 会改变排列
观感，已被否决）。语义照抄邮箱：**拖是「正在考虑」，松手才执行**，没有「滑开停在
那里的按钮」。

- **四档动作**（右滑 = 起点侧，左滑 = 末端侧）：

  | 方向 | 轻滑（< 判定线） | 重滑（≥ 判定线） |
  |---|---|---|
  | 右滑 | 归档（不确认） | 删除（弹确认框） |
  | 左滑 | 收藏 | AI 洞见（占位，尚未实现） |

  两侧各自成一条语义轴：**右滑是「收起来」**（先归档，再删除），**左滑是
  「留下来 / 用起来」**（先收藏，再交给 AI）。越远代价越大，所以唯一不可逆的
  那一档（删除）在最远的外侧，也唯一需要确认。
  - **划动归档不确认，长按菜单里的归档才确认。** 划动是「甩一下就完事」，弹框
    会把那个节奏打断；而且归档可逆——笔记只是从「全部」移到「已归档」，点一下
    筛选条就能拿回来。长按菜单本身已经是一次停顿，在那里问一句不碍事，也能
    提前说清笔记去哪了。取消归档两条入口都不问（`commitSwipe` 直接
    `onArchive()`，`CardMenu` 只在 `!archived` 时走 `confirmArchive()`）。
  - **AI 洞见只留了口子**（`onInsight` → 一个 toast 占位）。手势位置先占住，
    以后接上功能不必再重排一次四档。
  - 色相沿用三路：强调色（归档 / AI 洞见）、金（收藏）、红（删除）。
    **红色只给删除**——它是唯一不可逆的一档，同一档 alpha 下红比任何色都响。
- **拖动过程只做提示，不落状态。** 卡片 `translate` 出去多少，底下就露出多宽，
  颜色/图标/文案随「是否越过判定线」切换（`pastSecond()`），图标尺寸随进度连续
  放大（`pull()`）——连续的是露出量，离散的是跨线那一下，邮箱就是这样。
- **露出的底层与卡片同尺寸、同圆角，只是一层「从卡片边缘渗进去的淡光」。**
  这一条改过三次才成立，每一步都是实测否掉上一个：
  1. 底层宽度 = 露出宽度时，窄到圆角半径以下，两个圆角被夹成一条尖角薄片，
     看上去像从别处飘来的颜色。**底层必须始终是一整块卡片大小的板子**，
     卡片从它上面滑过去——滑动只是揭盖，不产生新形状。
  2. 整块平铺一种色相时，卡片边缘会有一条与它齐平的硬色边，那就是「跳」。而且
     渐变铺满整张卡时，露出来的永远是渐变里最深的一段，看起来就是一块色板。
     **色相只铺在真正露出的那一条上**（`width(Math.abs(swipeOffset))`），
     从露出侧 100% 淡到内侧 alpha 0，外侧沿用卡片圆角、内侧不留圆角。
  3. 纯色直接坐在页面背景上会被读成「另一张卡」而不是「这张卡底下的一层」。
     **先铺一层卡片自己的表面色**（`glassTint` / `ohos_id_color_card_bg`），
     色相叠在它上面。
- **颜色只用很低的强度，跨线只加深同一路色相。** 最终值是：金色首端 alpha
  `0.22`（浅）/ `0.15`（深），红色首端 `0.11`（浅）/ `0.09`（深），强调色首端
  `0.22`（浅）/ `0.16`（深）；跨线后的重档只把同一路色相提高一档，不换色相
  （重动作换的是图标、文案与文字色）。`favorite` 金与 `danger` 红在肉眼上比强调色
  更「响」，所以红色要压得最低——同一档 alpha 下它仍然是最显眼的那一块。
- **金与红的透明度写在资源里，强调色的透明度写在代码里。** `swipe_gold_hi/mid/lo`
  与 `swipe_red_hi/mid/lo` 在 `base` + `dark` 各一套，色相随主题走；强调色是运行期
  从 `Palette` 读的 hex，只能由 `accentAlpha()` 算（深色再弱一档，因为
  `Palette.accentDark` 本身是提亮过的）。`linearGradient` 只收 ARGB 字符串，
  收尾端必须是**同色相的 alpha 0**，不能用 `Color.Transparent`——后者在非预乘插值
  里中途往黑里沉，露出一道灰。
- **视觉验证要改 `swipeOffset` 初值后重建，不要靠手势中途截图。** 手势进行中
  ArkUI 不重绘组件树，`drag` 到一半抓到的仍是拖动前的界面（甚至拍到长按菜单）。
- **松手一律回弹到 0**（`settle(0)`），所以不存在「残留露出的操作区」。这条是
  必须的：双列卡片只有约 198 vp 宽，任何持久化的横向位移都会撞上单元格边界，
  左滑时标题会被裁掉半截（实测：`欢迎使用 纸见` 只剩 `使月 纸见`）。
- **判定线按卡片宽度算**（55%，夹在 96–150 vp）。固定值在 198 vp 的窄卡上几乎
  一滑就过、在平板宽卡上又够不着。死区 24 vp 以下是误触回弹。
- **必须用默认 `.gesture()`，不是 `parallelGesture` 也不是 `priorityGesture`。**
  两者都实测过：并行会让长按菜单和滑动**同时**成立（慢拖时菜单在页面中央弹出）；
  优先级则反过来让滑动完全不触发（卡片纹丝不动、菜单照常弹出）。默认绑定才走平台
  自己的竞争规则——移动超过 `distance` 判为滑动并取消长按，按住不动才轮到菜单。
- **`.gesture` 的 `offsetX` 是相对起手点的位移，不是逐帧增量**，直接赋值即可，
  不要累加。
- **`uitest drag` 的第 4 个参数是 velocity 不是时长**。用一个大值（如 500）去
  模拟「慢拖」等于瞬间甩完，什么都测不出来；要看拖动中的样子必须给 200–400 这类
  真实速度，并在另一进程里截图。
- 页签横滑已关（`HdsTabs` 与 `PlainShell` 的 `Tabs` 都 `.scrollable(false)`），
  否则卡片横滑会有一半概率切成切页签。代价：切页签只能点页签栏。

The reader re-parses in `onShown`, not `pushPath({ onPop })` — the latter only
fires when `pop(result)` carries a payload. It skips the reload while a draft is
open, so returning to the page cannot clobber what the user is typing.

### The Markdown engine (`markdown/`) is self-written

Contract and full rule list: **`docs/markdown-engine.md`**. Read it before
touching the parser or the renderer. Summary of the decisions that are easy to
undo by accident:

- **Flat AST, not a tree.** ArkUI custom components cannot reference themselves
  recursively, so block nesting is carried by two *orthogonal* fields — `indent`
  (list nesting) and `quoteDepth` (quote nesting) — and inline styling is carried
  by inherited boolean flags on flat `MdInline` spans, not by nesting.
- **Inline rich text must be `Text() { ForEach(...) { Span(...) } }`.** A nested
  `Text` inside the `ForEach` resets the parent component tracking on this
  compiler and the style inheritance breaks. This looks like a style choice and
  is not.
- **ArkWeb exists for one thing only: a block-level `$$…$$` formula.** KaTeX
  (MIT) is vendored offline under `rawfile/render/` and loaded by
  `components/FormulaWeb.ets`; body text, headings, lists, tables, code and
  inline `$…$` are all native. Mermaid and ECharts used to live here too, but
  nothing ever rendered them (see below), so both were deleted.
  **Do not vendor PlantUML** — upstream is GPL, which is incompatible with this
  project's licensing.
- **两种失败态，别混为一谈。** 页面加载失败或量高超时（`FUSE_MS` 6 s）→
  `FormulaWeb.FailCard()`，用 `MathLite` 把公式画出来。**语法错误不走这条**：
  `katex.render(..., { throwOnError: false })` 会自己把源码按 `errorColor` 染红
  就地渲染，用户看得到是哪一段写错了（实测 `$$\frac{1}{$$` 显示成红色的
  `\ rac{1}{`）。强行把它当加载失败，反而会丢掉 KaTeX 标出的出错位置。
- **图表为什么不在包里.** Mermaid (5.4 MB) and ECharts (1.1 MB) shipped for a
  full version while `MdView` rendered every `Chart` block as a 「图表渲染未接入」
  placeholder — 6.5 MB of engine that never executed once. `Chart` block kind and
  `isChartLang()` are gone; ` ```mermaid ` is now an ordinary fenced code block
  highlighted as source, which is *more* useful than a placeholder card claiming
  it will render later. If diagrams come back, do not re-vendor the full bundle:
  either draw a minimal native flowchart (a few hundred lines of ArkUI covers
  `graph TD` with boxes and arrows, which is what notes actually contain), or
  verify a tree-shaken Mermaid subset on device before budgeting for it.
- **行内 `$…$` 不进 WebView，它走 `MathLite`。** A screenful of inline formulas would
  be a screenful of WebView processes. `MdView.textFor()` linearises them to
  Unicode text (`E = mc²`) with no code background — they read as prose, not as
  code. Block formulas are few and worth typesetting, which is why only they get
  KaTeX.
- **「是块级公式」的判据必须收到行尾。** `isMathStart()` 只认两种形态：独占一行的
  `$$`，或**以 `$$` 开头且以 `$$` 结尾**的单行块。曾经只判「以 `$$` 开头」，于是
  `$$E = mc^2$$ 与行内 $a^2+b^2=c^2$ 两种` 被当成未闭合的公式块，**把后面整篇
  笔记吞成公式源码**，KaTeX 再把整段染红。一行里既有公式又有正文是笔记里的正常
  写法；退化成段落之后，行内的 `$$…$$` 与 `$…$` 都按行内公式收下——不收的话
  紧跟的 `^` 会被上标规则抓走，`$$E = mc^2$$` 渲染成 `$$E = mc2$$`。
  Corpus 用例：`tools/corpus/14-math-mixed.md`。
- **Inline images do not become `Span`s.** Only a stand-alone `![]()` paragraph
  renders a real image; an image mixed into a line degrades to its alt text,
  because an image inside a `Span` breaks the per-character coordinate system
  that text selection and annotations are built on.
- **Every cursor loop must guarantee progress.** A parser or tokeniser loop that
  can stall is a hard app hang, not a wrong render.

**Do not use `pushPath({ onPop })` to
refresh the list.** Its documented contract is that the callback fires only when
`pop(result)` is given a result; a plain Back press or `pop()` (as `TrashPage`
does) never fires it, which silently left the Notes list showing stale data.
Instead `Index.aboutToAppear` installs one interception on the stack:

```ts
this.pathStack.setInterception({
  didShow: (from, to, operation) => {
    if (operation === NavigationOperation.POP) { this.store.reload(); this.refreshList(); }
  }
});
```

`didShow` runs for every transition regardless of payload, so one hook covers
editor returns, trash returns and any future page. `refreshList` copies
`store.notes` into the component's `@Local notesSnapshot` array. **Render the
list from `notesSnapshot`, not directly from the singleton store**: the V2
dependency on a plain singleton's `@Trace` array is not reliable across a
`NavDestination` pop, and `listVersion`/`.id()` alone does not trigger a
rebuild. The snapshot assignment is what guarantees the note list refreshes
immediately on return.

**A `@Builder`'s parameters are passed by value — a `@Local` read inside the
argument expression is not a dependency of the built nodes.** The 设置 ›
WebDAV 同步 row was written as
`this.SettingRow('WebDAV 同步', this.davRowValue(), this.davRowSubtitle())`.
On device the `didShow` hook proved it ran (`davLastSync` logged the fresh
timestamp) yet the row kept rendering the pre-sync text — the framework
compared the evaluated strings, found them equal to the previous call, and
skipped the subtree, so reassigning `@Local davLastSync` never reached
`Text(subtitle)`. So the "copy the singleton into `@Local`, then reassign on
pop" pattern is only half the fix: the builder must also **read the state
itself**, with no parameters. `Index.WebDavRow()` is the worked example —
`if (this.davLastSync > 0) { Text(\`上次同步 · ${Index.formatSyncTime(this.davLastSync)}\`) }`
inside the builder body is what re-renders. Pass only genuinely constant
arguments to a `@Builder`; anything that changes at runtime belongs in a
parameter-less builder or a `@ComponentV2` with `@Param`.

`ReaderPage.persist()` skips the write when the markdown is unchanged. Without
that guard every open→close bumped `updatedAt`, reordered the list and
invalidated the `ForEach` key for no reason.

**A mis-tapped 新建笔记 must not leave a 无标题 husk behind.** `newNote()` has to
create the file up front (the reader loads by id), so `ReaderPage.goBack()` undoes
it: on exit it purges the note when it is **both** created from `+` this visit
(`createdHere`) **and** never edited (`touched` false). Two details are
load-bearing:
- The emptiness test is semantic, not a byte comparison against the created
  skeleton. The body is normalised on the way in and out (`'# 无标题\n\n'` comes
  back as `'# 无标题'`), so a byte compare marked every fresh note as edited and
  the discard silently never fired. Compare *meaning* (strip the auto H1 +
  whitespace), never bytes.
- Creation alone is not the rule. A note the user actually typed into must survive
  even if they leave in two seconds, so `touched` (set on the first real edit,
  which also covers type-then-delete-everything) is required as well.
The purge is `NoteStore.purgeNote()`, deliberately **not** `deleteNote()`: the
user deleted nothing, so nothing belongs in 回收站 or should hold a retention
slot. The discard decision lives in exactly one place (`goBack()`), so a note
cannot be purged after a save already wrote it.

**Do not pass a `Note` object into `NoteCard`.** `NoteCard` takes immutable
primitive props (`noteId`, `title`, `excerpt`, `tags`, `archived`, `favorite`,
`updatedAt`); the `ForEach` key is `${note.id}-${note.updatedAt}`. This forces a
fresh card when an existing note is edited. Rendering `store.notes` directly, or
passing the same mutable `Note` reference through `@Param`, will leave the card
showing the pre-edit title/excerpt until a tab switch.

UI immersion uses **HDS** (`@kit.UIDesignKit`; `HdsNavigation` + `HdsTabs` +
`hdsMaterial`), gated on `deviceInfo.sdkApiVersion >= HDS_MIN_API` (23). Below
that the app renders `Index.PlainShell()` — a plain `Navigation` + `Tabs` — so
an older device degrades instead of crashing. The HDS libraries live in the
**`hms` SDK** (`sdk/default/hms/ets/api/@hms.hds.*`), not in `openharmony/ets`.
- **Do NOT call `setWindowLayoutFullScreen(true)`. It breaks HDS.** With it
  enabled the title bar's custom node collapses to 17 vp and its buttons squeeze
  to 9 vp, clipping the icons to ~3 px. HDS sizes the title bar from the
  status-bar inset itself, so manual fullscreen conflicts with it. Remove the
  call and let `.ignoreLayoutSafeArea` on the HDS container do immersion — that
  is what makes the action buttons render at their real 40 vp. **Re-confirmed**
  on the current MINI + `stackBuilder` shell: with fullscreen layout
  `HdsTitleBar` measured `[0,117][1320,168]` — 51 px, i.e. 17 vp, with the title
  text clipped to 16 px. The old measurement still holds; do not re-litigate it.
- **Immersing the system bands is a *backdrop* job, not a layout job.** The
  content root legitimately starts at the status-bar bottom (`root` at
  `[0,117]`), so by default the status bar and the gesture bar show the
  *window's* background and the page looks cut off from them (the "背景分割"
  report). The fix is `.expandSafeArea([SafeAreaType.SYSTEM],
  [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])` on the node that actually **paints**
  the background — in `Index.PageBackdrop` that is the filled/gradient `Column`,
  not the wrapping `Stack`. Two traps:
  - Expanding the **wrapper `Stack`** does not help: the gradient child stays
    sized to the unexpanded box, so the bands still show through. Expand the
    painting node.
  - Expanding the **shell/root `Stack`** is wrong: it moves `Navigation` with it
    and re-invalidates `TITLE_BAR_CLEARANCE`. Only the `HitTestMode.None`
    decorative layer may expand.
  Full-bleed pages (`ReaderPage`, `TrashPage`, `WebDavPage`) need the same
  treatment, on **both** edges, in a two-layer `Stack`:
  ```
  Stack({ alignContent: Alignment.TopStart }) {
    Column().width('100%').height('100%').backgroundColor(page_bg)
      .hitTestBehavior(HitTestMode.None)
      .expandSafeArea([SYSTEM], [TOP, BOTTOM])   // backdrop: expands
    Column() { /* header + content */ }           // content: never expands
  }
  ```
  Expanding the page's *content* `Column` instead drags the header under the
  status bar. Expanding only `BOTTOM` (the first attempt here) leaves the top band
  on the window background — which **looks fixed in light mode** because the
  window background is near-white and `page_bg` is `#F5F6F8`; it only became
  obvious in dark mode, where the band measured `(0,0,0)` against a `(16,16,18)`
  page. Always verify this in **dark mode**, by pixel-sampling the top band, not
  by eye on a light build.
- **A `NavDestination` page owes a compact header, not a status-bar inset.**
  Because the content root already begins below the status bar, `NavDestination`
  content needs **no** top inset of its own. The removed `EditorPage` (and
  `TrashPage` before it) used `height(96)` + `padding({ top: 40 })` on the
  reasoning that it had to clear the status bar; the result was 40 vp of dead
  space and a header that read as "下沉过多" (button measured at `[24,255]`
  instead of the bar's top). Headers are now a plain **56 vp** row with no top
  padding — back button at `[24,135]`, flush with the content top. No page may add
  a status-bar inset while manual
  fullscreen stays off.
- **`HdsNavigation` is the router.** Use `HdsNavigation(this.pathStack)` with
  `.navDestination(this.pageMap)`; do **not** wrap it in an outer `Navigation`.
  Nesting produced two title bars and made the shell overflow its parent
  (measured `Column` ending at 2148 px inside a 2232 px window).
- **The page must reserve the title-bar band itself.** HDS draws `NavBarContent`
  at the *same origin* as the title bar, so content flows under it. Every tab
  root carries `padding({ top: TITLE_BAR_CLEARANCE })` — measured **96 vp** in
  MINI mode with `.hideBackButton(true)`. Put that clearance in `padding`, **not**
  in a `Blank()` child: `Blank` expands to consume free space and silently
  ignores `height()`, which cleared only 69 vp and let the header overlap the bar.
  Note the origin: with `ignoreLayoutSafeArea` the padding resolves from
  **window y = 0**, not from the content top, so the value is the bar's absolute
  bottom edge in vp (285 px / 3), not a delta.
- **Use `HdsNavigationTitleMode.MINI`, not `FULL`, and build the whole title row
  in `stackBuilder`.** FULL reserves a separate large-title band *below* the
  `stackBuilder` row (measured: bar 117…453 px, rows at 117…285 and the title at
  316…421), so the page title and the action buttons land on two different lines —
  not the reference layout. MINI keeps the bar to one 56 vp row, and leaving
  `content.title` unset leaves that row entirely to `stackBuilder`. MINI also
  injects its own back button at the leading edge (measured x 48…168, exactly
  where the title starts), so `.hideBackButton(true)` is required on the root.
- **`stackBuilder` centres its child.** A `Row` there is content-sized and lands
  in the middle of the bar (measured x 504…816 of 1320). Claim `.width('100%')`
  and drive the layout from the Row's own children (a `layoutWeight(1)` title
  plus trailing buttons) rather than `justifyContent`.
- **The built-in `menu` icon slot is unusable on this device image**: it renders
  every icon (ResourceStr, `SymbolGlyphModifier`, `Image`) at ~3 px inside a
  9 vp-tall button, in FULL and MINI, with every `IconStyleMode` and with
  `materialType` NONE. Use `stackBuilder` (the documented custom top area).
- **Title-bar actions are glass, not accent.** Both circular buttons are a
  three-layer stack: `backgroundEffect({radius: 24, saturation: 1.8})` for a real
  backdrop blur, a `glass_hi` specular sheen on the upper half, and a 1 vp
  `glass_border` rim. Glyph colour is neutral `sys.color.ohos_id_color_text_primary`.
  A saturated accent disc at 44 vp reads as a solid chip and fights the
  translucency.
- **Use `backgroundEffect`, not `backgroundBlurStyle`, for hand-built glass.**
  `backgroundBlurStyle(COMPONENT_THIN)` desaturates whatever is behind it, so the
  surface reads as frosted plastic. `glassEffect()` centralises
  `radius: 24 / saturation: 1.8 / brightness: 1.04 / color: glass_tint` so the
  title buttons, search field and chip capsules share one glass signature instead
  of each drifting to its own blur strength.
- **Glass needs a specular layer, not just a tint.** A flat translucent fill looks
  like a grey disc. Each glass surface wraps its content in a `Stack` whose first
  child is a `Column` with a `linearGradient` from `glass_hi` to transparent
  (stops 0.0 → ~0.6), plus `.clip(true)` on the parent. That upper-rim highlight
  is what actually reads as glass.
- **HDS surfaces get `lightColor: glass_hi`.**  `floatingBarStyle().lightColor` is
  the tab bar's rim highlight, so the HDS bar and the hand-built glass buttons
  look like one material family.
- **Glass strength is a user setting (`glassLevel`), and its gears follow the
  platform's vocabulary, not an invented scale.** The official model has two
  independent axes and they must stay independent:
  **算力等级** (`uiMaterial.MaterialLevel` = EXQUISITE/GENTLE/SMOOTH, i.e. 高/中/低)
  is a property of the *device* — `uiMaterial` exposes it read-only via
  `getGlobalMaterialLevel()` and the docs state it 不支持设置. **厚度**
  (`uiMaterial.ImmersiveStyle` = ULTRA_THIN…ULTRA_THICK) is the knob a designer
  exposes. `hdsMaterial.MaterialLevel` can force a compute level, but the docs
  warn that pinning EXQUISITE/GENTLE on a low-power device 可能造成卡顿和发热 and
  explicitly recommend `ADAPTIVE`.
  So `glassLevel` encodes a *policy*: `GEAR_ADAPTIVE` (0, the default, defers to
  the device) / `GEAR_HIGH` (1) / `GEAR_MEDIUM` (2) / `GEAR_LOW` (3). Those are
  contiguous indices, deliberately **not** the `hdsMaterial.MaterialLevel` values
  (ADAPTIVE is 10 there, which would leave a gap); `materialLevel()` translates.
  Five tables read the gear and must stay aligned: `materialLevel()`
  (ADAPTIVE/EXQUISITE/GENTLE/SMOOTH), `glassEffect()` (`radius` 24/32/24/16,
  `saturation` 1.8/2.1/1.8/1.4, `brightness` 1.04/1.06/1.04/1.02),
  `glassSheenStop()` (0.62/0.74/0.62/0.4) and `glassRimWidth()` (1/1.5/1/0.5).
  Gear 3 is still visibly glassy on purpose — a "low" that is a flat fill makes
  the setting pointless. Changing gear repaints in place; do not remount the
  shell for it.
- **`deviceTier` is read-only and only ever displayed.** `aboutToAppear` probes
  `uiMaterial.isImmersiveMaterialSupported()` then `getGlobalMaterialLevel()` and
  the settings row renders `本机高算力 · 自适应优先`, so the 自适应 gear is
  verifiable rather than a black box. Do not use it to drive layout.
- **Immersive material (`systemMaterial`) has a hard scope limit — but a `Toggle`
  carrier is the way around it.** Per `@ohos.arkui.uiMaterial` it only takes effect
  inside a `Navigation` / `NavDestination` title bar, a `barPosition(End)`
  horizontal bottom tab bar, or the listed dialog/Slider/Toggle/Select cases —
  "在其他区域中设置沉浸光感效果不生效". **Verified on device**: a chip capsule in the
  page content with `.backgroundColor(Color.Red).systemMaterial(...)` kept the red
  fill, proving the material never applied. `Toggle` *is* in the documented list,
  so `components/MaterialLayer.ets` paints the material from an invisible
  `Toggle({ type: ToggleType.Button, isOn: false })` and the real content draws on
  top of it. Every content-area surface (笔记卡片, the 筛选条/排序条 capsules) now
  goes through that carrier instead of the hand-built `glassEffect()` stack.
  `titleBar.content.bottomBuilder` exists and *would* move the chips into scope,
  but it grows the title bar and invalidates `TITLE_BAR_CLEARANCE`, so it is not
  worth it for two chips.
- **The carrier must be mounted through `.background()`, not as a `Stack` sibling.**
  This one cost a broken build on device. `MaterialLayer` sizes itself with
  `LayoutPolicy.matchParent`, which inside a `Stack` resolves against the *flow's
  available size* — every 笔记卡片 grew to the full grid height and one row filled
  the screen. `.background(builder)` lays the carrier out against the node's
  already-measured box, so it cannot inflate anything. Order inside the builder is
  also load-bearing: carrier first, then a translucent veil, then the text as the
  node's own children — the material's visual layer is drawn **above**
  `backgroundColor` but **below** children, so an opaque `backgroundColor` hides it
  and a bare carrier is swallowed by the near-uniform accent backdrop (the grid
  lost all visible surface). The veil is `glassTint()`, currently `#D1FDFEFF` /
  `#CC1C1C1E`: at 70 % the sampled card came out *darker* than the page
  (`#EDF5F6` vs `#F1F9F9`), i.e. a slab sunk into the background; ~82 % puts it
  above the backdrop while still passing the material's edge refraction.
- **A `@Builder` used as `.background()` needs a typed options object.**
  `.background(this.CardSurface(), { align: Alignment.Center })` fails ArkTS with
  `arkts-no-untyped-obj-literals`, and the resulting parse failure cascades into
  every attribute after it (`arkts-no-standalone-this`, `arkts-no-comma-outside-loops`,
  90 errors from one line). Hoist a module-level `const CARD_BG_OPTIONS:
  BackgroundOptions = { align: Alignment.Center }`.
- **Gating: probe once, never per widget.** `glassOn()` requires both
  `hdsSupported` (API ≥ 23) and `immersiveSupported` (`MaterialType.IMMERSIVE` in
  `getSystemMaterialTypes()`). When false every surface falls back to its opaque
  fill — never to transparent, which would make the note disappear. The material
  also follows the **system** light/dark setting, not the app's 外观 choice (the API
  exposes no switch), which is why the veil is chosen by `activeDark()` rather than
  by the platform.
- **`ImmersiveStyle` must be resolved through a function, never a module-level
  constant.** `const S = uiMaterial.ImmersiveStyle.THIN` dereferences `uiMaterial`
  at *module load*; on a device below API 26 that is `undefined`, the `.THIN` access
  throws **outside any `try/catch`**, the module fails to load and the app crashes
  on launch — not "no material", but no app. `MaterialLayer.styleFor()` exists for
  exactly this.
- **The two title-bar circles and the search field use the real material.**
  They live in `stackBuilder`, which is in scope. `CircleAction` /
  `SearchField` call `.systemMaterial(this.immersiveMaterial())` and fall back to
  the hand-built stack when `immersiveSupported` is false. Consequences:
  `backgroundColor` must be `Color.Transparent` (the platform resets it to
  transparent on high/medium tiers anyway, and on low tiers paints with
  `materialColor`), **never** set `border` (`borderWidth` is reset to none), and
  the circle comes from `clipShape(CircleShape)` rather than `borderRadius`.
  `applyShadow` defaults true and overrides the `shadow` attribute — set it
  **false** here (see the 边缘光感 entry above).
  `immersiveMaterial()` maps the gear to `ImmersiveStyle`
  (自适应 → REGULAR, 高 → ULTRA_THICK, 中 → REGULAR, 低 → THIN) and sets
  `interactive: true` for the press deformation. Note `ImmersiveStyle` has no
  effect on low-tier devices. **Do not** set `interactive: true` on a *card*
  carrier: on the reference device it made the material stop rendering entirely.
- **One backdrop for the whole shell, not one per tab.** `build()` is a `Stack`
  of `PageBackdrop()` + `Navigation`, and `HdsShell`/`PlainShell` contain no
  backdrop of their own. Per-tab backdrops each computed their own gradient and
  glow offsets, so a horizontal tab swipe slid two gradients past each other and
  their edges met mid-screen — the seam users reported. Hoisting it also means the
  title bar and the floating capsule sit over one continuous surface, which is
  what makes the material sampling coherent. Do not reintroduce `PageBackdrop()`
  inside a `TabContent`.
- **`SegmentButton` takes a `kind` (`SEG_THEME` / `SEG_BACKGROUND` / `SEG_GLASS`)**,
  not a boolean. Three independent segmented rows on the settings page would
  otherwise need three flags plus a precedence rule. Both `SegmentButton` and
  `segmentSelected()` switch on it, so a new row must add a constant to both.
- **A tag is a query, not a private filter.** Tapping a tag on 标签 calls
  `filterByTag(tag)`, which sets `query` **and** `searchExpanded` and switches to
  the notes tab, so the constraint is visible in the search field and clearable
  with ×. Routing it through the same search state is deliberate: a separate
  `tagFilter` field left the grid silently filtered while the page looked
  identical to the unfiltered list. `filterByTag` does **not** focus the field —
  focusing pops the keyboard over the results the user came to read. Note it
  cannot reuse `switchTab()`: that helper force-collapses `searchExpanded`.
- **Tags are written from the 笔记卡片 long-press menu, through a sheet.** They
  used to be reachable only by hand-editing the `tags:` line in the frontmatter,
  which made 标签 a read-only view of a field no UI could write. 笔记卡片 ›
  「标签…」 opens `Index.TagSheet()`: applied tags render as removable accent
  chips, a `TextInput` + 添加 adds new ones, and 已有标签 lists the vault's tags so
  a note reuses `工作` instead of inventing `work` beside it.
  Two constraints:
  - **The working copy is a `@Local` array, not the `Note`.** Mutating the note
    mid-edit would repaint the grid behind the sheet on every keystroke, and a
    cancelled sheet would already have changed the note. 完成 is the only writer.
  - **`NoteStore.setTags()` must not route through `saveNote()`.** `saveNote()`
    renames the file to match the body's H1 and re-derives the excerpt; tagging
    changes no prose, so that would rename files behind the user's back and
    invalidate every `ForEach` key. `setTags()` rewrites the frontmatter and bumps
    `updatedAt` (so sync sees an edit and pushes it), nothing else.
  - A `@Local` array is observed on **assignment**: `push` into it and nothing
    repaints. Use `concat` / `filter` and reassign.
- **Search expands in place; there is no always-visible search field.** The title
  row swaps `Text(tabTitle)` + magnifier for a rounded `SearchField()` when
  `searchExpanded` is set, and collapses back with the query cleared. A second
  persistent search box under the title duplicated the same affordance and cost a
  full row.
- **Pin the title colour.** If `content.title` is ever used again, HDS defaults it
  to white, which is invisible in light mode. The field is three levels deep —
  `TitleBarStyleOptions.originalStyle` / `.scrollEffectStyle` → `contentStyle` →
  `titleStyle.mainTitleColor` — and both the resting and the scrolled style need it.
- **`ScrollEffectType.GRADIENT_BLUR` does not exist** in the local SDK. The enum
  is `COMMON_BLUR = 0` / `GRADUAL_BLUR = 1`; the immersive variant used here is
  `IMMERSIVE_GRADIENT_BLUR`.
- **A `WaterFlow` `FlowItem` cannot span columns.** A full-width header placed
  inside a two-column flow gets exactly one column's width and shears against
  the grid. The header is a full-bleed block *above* the `WaterFlow` instead.
- **`WaterFlow` measures a `FlowItem`'s child against the whole flow**, not
  against the column slot: a card whose content is wider than one column (long
  title + wrapping tag `Flex`) expanded to the full grid width and overlapped its
  neighbour. Give each cell an explicit width — `Index.columnWidth()` derives it
  from the real display width, density and `SIDE_INSET`.
- **Each tab gets its own `Scroller`** through `HdsTabsController.bindScroller(i,
  scroller)`; that is what preserves independent scroll positions across tab
  switches and what `bindToScrollable([scroller])` links to the title bar.
- The floating bar is HDS-owned: `.barPosition(BarPosition.End)`, `.vertical(false)`,
  `.barOverlap(true)`, plus `barFloatingStyle({ barWidth, barBottomMargin: 28,
  gradientMask, systemMaterialEffect })`. `HdsTabsFloatingStyle` exposes no
  visibility field, so the bar cannot be collapsed by hand — do not reintroduce
  the old hand-drawn `FloatingBar()`; `translate`/`opacity` on a custom pill is
  what used to fake it.
- **Tab selection follows the user's accent setting**, not the fixed
  `sys.color.ohos_id_color_activated` (explicit user decision). Unselected uses
  `sys.color.ohos_id_color_bottom_tab_icon_off`.
- Material degrades by *level*, not by presence. `materialType()` /
  `materialLevel()` are the single source of truth. IMMERSIVE is always requested
  when the device reports it; the *level* follows the user's `glassLevel` gear,
  translated to the platform enum — `GEAR_ADAPTIVE` → `ADAPTIVE` (the default and
  the officially recommended value), `GEAR_HIGH` → `EXQUISITE`, `GEAR_MEDIUM` →
  `GENTLE`, `GEAR_LOW` → `SMOOTH`. `aboutToAppear` probes
  `hdsMaterial.getSystemMaterialTypes()` once and, if it does not contain
  `MaterialType.IMMERSIVE`, the pair falls back to ADAPTIVE/SMOOTH. On the emulator
  it returns `[101]`, i.e. IMMERSIVE is present, and
  `uiMaterial.getGlobalMaterialLevel()` reports the high tier (0). Do not call
  either probe per-widget — probe once, read the fields.
- **Card surfaces use `sys.color.ohos_id_color_card_bg` with `borderRadius` 26**,
  not `glass_bg`. Press/hover feedback comes from `.clickEffect()` /
  `.hoverEffect(HoverEffect.Auto)`: this toolchain rejects both the inline object
  literal and `@Styles` function references as `StateStyles` values, so
  `.stateStyles()` is not usable here.
- **The filter and sort groups share one row.** Two capsules side by side
  (`ChipGroup(0)` = 全部/归档/收藏, `ChipGroup(10)` = 按修改/按标题/按创建),
  each `layoutWeight(1)`, capsule 34 vp / radius 17, chip 28 vp / radius 14,
  label 12 fp. Two stacked rows wasted a whole band and pushed the grid down.
- **筛选项一律 2 字、排序项一律 3 字.** The chips are `layoutWeight(1)`, so equal
  widths with unequal label lengths read as misaligned text — 「已归档」3 字 between
  two 2-字 chips, and 「最近修改」4 字 between two 3-字 chips, both looked like an
  error. Keep the two groups internally uniform when renaming a chip. The active
  sort chip is the only one that carries an extra `↑` / `↓`.
- **All floating surfaces share one inset.** The title row, the chip row and the
  bar are full width minus `SIDE_INSET` (16 vp). Never combine `width('100%')`
  with horizontal `margin`: width wins and the node stays full-bleed (the filter
  row measured 0…1320 while the search field measured 49…1271). Put the inset on
  a wrapper's `padding`. Same for a `position()`ed node: `position` takes it out
  of flow, so `margin` does not inset it.
- **Float clearance lives inside the scrollable, not in padding.**
  `contentEndOffset(130)` on the grid gives the capsule its room; a bottom
  `padding` would instead clip the content early and hide that it continues under
  the bar.
- The window no longer uses manual fullscreen; `common/WindowService.ets` owns
  status/navigation bar content colours and light/dark icon state. Call
  `WindowService.applySystemBars(isDark)` after applying a stored/manual theme,
  **and again from `Index.aboutToAppear`** — the stored light/dark choice is
  otherwise lost, because the window's system bars are re-initialised when the
  stage loads content. `services/SettingsStore.ets` persists `themeMode` (`0`
  follow system, `1` light, `2` dark), `accentMode` (`0` blue, `1` teal, `2` amber),
  `editorFontSize` (14–22 px), `editorLineHeight` (**75–150**, i.e. 0.75–1.50×,
  default 120; a range topping out at 2.20× is double-spacing and the useful tight
  end sits below 1.10), `cardRadius` (8–36 vp, default 26), `simpleEditing`
  (default `false` = 分块) and `formatBar` (default `false`), plus `glassLevel`
  (see the immersion section).
  `Index.PageBackdrop` is drawn **once** behind the whole shell, not per tab, so
  the background does not jump when switching tabs and the swipe has no seam.
- **背景 is 光感 only, and it follows 强调色.** There is no 背景样式 setting any more:
  the retired `backgroundStyle` preference (`0` solid / `1` gradient /
  `2` gradient + glow) was removed with its 分段控件 row, because a solid fill
  contradicts the 光感 look and the two "gradient" variants were the same shape
  with an extra orbital glow. `Index.PageBackdrop` now has exactly one form —
  an accent gradient (`Palette.AccentScheme.pageTop/pageMid/pageBottom`) plus four
  `accentGlowColor()` orbs — so switching 强调色 repaints the whole background with
  no separate control. `KEY_BACKGROUND` is deliberately left documented in
  `SettingsStore.ets` but unread: an installed build still holds a value under it
  and Preferences never garbage-collects, so the name is kept to stop someone
  reintroducing a parallel field that disagrees with the palette.
- **The bottom 页签栏 is a floating capsule, and its width comes from a *bucket*.**
  `HdsBarWidthRangeOptions` chooses by **window** width: `smallWidth` when the tab
  area is **< 440 vp**, `mediumWidth` for 440–600, `largeWidth` for > 840. This
  device is exactly 440 vp, so it falls in the **medium** bucket — the old
  `mediumWidth: 400` produced a 400 vp bar on a 440 vp screen (measured
  60…1260 px of 1320), i.e. a full-width slab with 20 vp of air, which read as
  「页签栏过宽」. Now 280/300/340, measured `[210,1980][1110,2148]` = 300 vp, so it
  reads as a capsule. Reduce all three buckets together: leaving `large` wide makes
  the tablet layout *relatively* wider than the phone one.
- **The title-bar circles' outline must come from `borderRadius`, not `clipShape`.**
  A 44 vp node with `borderRadius(22)` *is* a circle, and it is the shape the
  material rasterises. `clipShape(CircleShape)` only clips the node's drawing — the
  material still paints its own default rounded rectangle underneath, so the circle
  cuts its corners away and leaves the rectangle's four straight edges visible as
  bright arcs at 12/3/6/9 o'clock. That is the 「边缘光感异常」 report: obviously
  broken in dark mode, where the arcs are white slivers on a dark disc, and easy to
  miss in light mode. Measured at 5× zoom before/after: four disconnected arcs →
  one continuous hairline rim.
  The same rule retires `.clip(true)` on the search capsule: clipping the rim to an
  inner rounded rect while the material paints on the node's bounds produces the
  same artefact. Nothing in that capsule needs clipping — its children sit inside
  the padding.
- **`applyShadow: false` is still right, but it was not the cause above.** The
  documented default is `true` and it overrides the `shadow` attribute, so a small
  clipped control picks up a crescent of shadow inside its rim. Fixing it removed a
  grey halo (gap between the two buttons measured `#E5EAF0` → `#EFF4FA` against an
  `#EBF1F6` page) but left the arcs, which is why the shape fix was needed
  separately. Keep both.
  `lightEffect` is set to `accentColor()` — its documented default is
  `Color.White`, and a white specular on a near-white backdrop is invisible, so a
  press produced no feedback at all.
- **Accent colours cannot come from `$r('app.color.accent')`.** ArkUI resolves
  resources at build time, so a runtime-selectable accent has to be passed as a
  hex string. `common/Palette.ets` (`AccentScheme`) owns the light/dark pair for
  every accent-dependent colour; components that need it take
  `@Param accentColor: string` (and `accentChipColor` where a tint is needed)
  from `Index.accentColor()`. Do not hardcode `#0A59F7` in a component.
- The renderer follows the accent + typography settings directly: `MdView` takes
  `bodySize`, `lineHeight`, `dark`, `accentColor` as `@Param`s from
  `ReaderPage.typography()`. There is no CSS/Web bridge to keep in sync any more
  (the Crepe surface that needed one is gone).
- **There is no FAB.** The new-note action lives only in the title bar (per the
  Cube redesign). If a floating action ever comes back, place it with
  `Alignment.BottomEnd` + `margin`, never with `position({x: <pixels>})`:
  `position` takes vp and the old `position({x: 1180, y: 1900})` put it entirely
  off a 440 vp-wide screen, so it silently never appeared.

Rules:

- **Dependency direction**: `pages → components/viewmodels → services → models`.
  `models` must not import UI or services. `services` must not import pages.
- **One page = one responsibility.** Page `build()` composes components; data
  loading goes in `aboutToAppear` or a view model method.
- **Shared code**: if a second HAP/HSP needs the same code, extract a HAR
  (`har` module) rather than copying. Use an HSP only for shared runtime UI or
  large resources. Do not split modules prematurely.
- **Routing**: register pages in `main_pages.json`; use `Navigation` for new
  flows and `NavPathStack` for parameters/back behavior.
- **Naming**: `PascalCase.ets` for components/classes; `camelCase` for
  functions/variables; resource names `snake_case`.
- **UI vocabulary is fixed — use `docs/ui-glossary.md`.** When discussing a UI
  element (in a request, a commit message, or a code comment) use the glossary's
  normative Chinese term, not a paraphrase. The load-bearing distinctions:
  「标签」= tag vs 「页签」= tab; the bottom bar is 「页签栏」 (HDS `TabBar`, styled by
  `Index.floatingBarStyle()`), never 「标签栏」or 「tab 栏」; the chips under the search
  field are 「筛选条」/「筛选项」 (全部/已归档/收藏) and 「排序条」/「排序项」
  (updated/title/created), never 「切换栏目」; a grid item is 「笔记卡片」 but a list item
  is 「行」; a bare 「标题」 is never acceptable — say 页面标题 (the HDS 大标题) / 卡片标题 /
  编辑器标题. Locate code as `file › @Builder name` (e.g. `Index.ets › TitleActions()`).
- **Logging**: use `hilog` with `DOMAIN = 0x0000` and `TAG = 'HMStart'` (or a
  feature tag). Never log secrets or full user data.

## 7. ArkTS / ArkUI rules

### State (V2)

```ts
@ObservedV2
export class CounterModel {
  @Trace count: number = 0;
  increment(): void { this.count++; }
}

@ComponentV2
export struct CounterCard {
  @Param model: CounterModel = new CounterModel();
  @Event onChanged: () => void = () => {};
  build() {
    Column() {
      Text(`${this.model.count}`)
      Button('+1').onClick(() => { this.model.increment(); this.onChanged(); })
    }
  }
}
```

- `@Local` for component-owned state; `@Param` for inputs; `@Event` for outputs.
- `@ObservedV2` + `@Trace` for shared observable objects. Mutate `@Trace`
  fields; reassign arrays/maps to trigger updates.
- Use `@Provider`/`@Consumer` for deep trees; avoid prop drilling.
- `PersistenceV2.connect(Type, () => new Type())` for small persistent UI state;
  `preferences` for settings; RDB for relational data.

### UI

- Use `Navigation` with `NavDestination` and `NavPathStack`. Pass typed params;
  read them in `onReady`/view model, not from global mutable state.
- Use `GridRow`/`GridCol` or `breakpoints` for responsive layouts; test at
  phone width and a wide window. Do not hardcode pixel widths for content.
- Use `LazyForEach` with a stable key for long lists; set `cachedCount`.
- Use `@Reusable` for repeated list items with expensive subtrees.
- Use `$r('app.color.*')`/`$r('app.string.*')`; add `resources/dark/` variants.
- Respect safe areas (`expandSafeArea` / `SafeAreaPadding`) and avoid content
  under the status bar/navigation bar.
- Add `.accessibilityText()`/`.accessibilityDescription()` for icon-only
  controls; ensure tap targets ≥ 48vp.
- Use `promptAction.showToast` for transient feedback; `AlertDialog` for
  destructive confirmations.

### Concurrency / performance

- No heavy parsing, IO, or crypto in `build()` or `aboutToAppear` on the UI
  thread; use `taskpool` (`@Concurrent` functions only reference imports/locals)
  or `worker`.
- Avoid `Date.now()` for timestamps in persisted data; use
  `systemDateTime.getTime()`.
- Profile before optimizing; use `hilog`/ArkUI Inspector rather than guesswork.
- Do not create new objects in hot `build()` paths; memoize in view models.

### Data / security

- `preferences`: small key-value settings, flush after writes.
- RDB (`@kit.ArkData`): relational data, parameterized SQL, migrations.
- Asset Store Kit: tokens/passwords/API keys; never in `preferences` or source.
- Network: `@kit.NetworkKit` HTTP; declare `ohos.permission.INTERNET`; handle
  timeouts, non-2xx, and cancellation; never log Authorization headers.
- Files: use the app sandbox (`context.filesDir`, `cacheDir`); request file
  access through pickers rather than broad storage permissions.

### Error handling

- Type caught errors as `BusinessError` (`@kit.BasicServicesKit`) and check
  `code`. Do not swallow errors silently; log with context and surface a user
  message.
- Async UI updates: guard against updating after page disappearance.

## 8. Signing and emulator

Preferred (official, requires a Huawei developer account):

```powershell
devecocli auth login --no-prompt   # user completes browser auth
devecocli signature generate --product default
devecocli build
devecocli run
```

This writes `signingConfigs` into `build-profile.json5` and materials under
`~/.ohos/config/`. Do not commit those materials.

Offline/local fallback (no Huawei account, emulator only):

- `signing/` contains the OpenHarmony **local debug** cert chain and a
  bundle-specific debug profile (`hmstart-debug.p7b`) generated with
  `hap-sign-tool.jar`. See `signing/README.md`.
- Use `scripts\run.ps1` (or `scripts\sign-and-install.ps1`) to build unsigned,
  sign with the local chain, install, and launch. This chain is for the
  emulator only; never ship it.
- If `devecocli run` reports `install sign info inconsistent`, uninstall the
  app first (`scripts\run.ps1 -Uninstall`) or regenerate the local profile.
- `build-profile.json5` intentionally keeps `signingConfigs: []` because
  hvigor’s DevEco-style signing config expects encrypted passwords. Do not add
  plaintext passwords there; use the script fallback or official signing.

Emulator:

```powershell
. .\scripts\env.ps1            # sets OHOS_HDC_SERVER_PORT=18710
devecocli emulator list
devecocli emulator start puraxview --hdcport 15000
devecocli device list
scripts\run.ps1                # local signing fallback if no signingConfigs
```

If `hdc list targets` is empty or hangs while the emulator is running:

1. **Check the port conflict first.** WSL2 mirrored networking exposes
   `sshd-sess` on `8710`; the default hdc server cannot bind there. Run
   `Get-NetTCPConnection -LocalPort 8710 -State Listen` and
   `wsl ss -ltnp | grep 8710`. If `wslrelay`/`sshd-sess` owns it, set
   `OHOS_HDC_SERVER_PORT=18710` (already in `scripts/env.ps1` and MCP wrappers)
   and use that port consistently.
2. Kill stale hdc clients: `Get-Process hdc | Stop-Process -Force`.
3. Start the server on the alternate port: `hdc -s 127.0.0.1:18710 start`.
4. Re-add the emulator: `hdc -s 127.0.0.1:18710 tconn 127.0.0.1:15000`.
5. Verify: `hdc list targets -v` and `devecocli device list`.

The emulator accepts hdc ports **10000–16555**; `5555` is rejected by the
current Emulator 7.0. Use `15000`. The hdc *server* port and the emulator
bridge port are different: server `18710`, device target `127.0.0.1:15000`.

## 9. Verification checklist

Before reporting success:

- [ ] `devecocli check arkts` on changed files: no errors.
- [ ] `devecocli build`: BUILD SUCCESSFUL; artifact path captured.
- [ ] App installed and launched; `app_state` shows the app in foreground.
- [ ] Screenshot reviewed (no blank screen, no clipped text, dark mode sane).
- [ ] `ui layout` contains the expected text/ids; interactions tested.
- [ ] Error logs empty or explained; crash logs checked if the app restarted.
- [ ] Resources: no hardcoded user-facing strings/colors; dark variant added.
- [ ] Permissions: minimal, with `reason`/`usedScene`; runtime request handled.
- [ ] No secrets or signing material in the diff.

## 10. Documentation sources

Priority order:

1. Local SDK declarations:
   `D:\deveco\command-line-tools\sdk\default\openharmony\ets\api\*.d.ts`,
   `...\ets\component\*.d.ts`, `...\ets\kits\*.d.ts`.
2. `devecocli docs search/read` (bundled official docs; works offline).
3. MCP `harmonyos-knowledge` (`searchDocuments` → `getDocumentsById`) for the
   latest official docs (sync delay ≤ 30 min; `getDocumentsById` max 10 docs).
4. Official site: `https://developer.huawei.com/consumer/cn/doc/`.
5. Project-specific decisions in `docs/` and this file.

When docs conflict, prefer the local SDK for compile-time truth and the
knowledge MCP for guidance. Record any version-specific decision in the PR or
commit message.

## 11. Anti-patterns / common failures

- **V1 MCP config**: OpenCode V2 requires `mcp.servers`, `disabled` (not
  `enabled`). The DevEco CLI `init --mcp` still writes the V1 shape; keep the
  wrapper/config in this repo as the source of truth.
- **LSP in OpenCode V2**: `lsp: true` exists but V2.0.32 has no functional LSP
  runtime; do not rely on `devecocli serve lsp`. Use `devecocli check arkts`.
- **DevEco CodeGenie MCP**: `@deveco-codegenie/mcp` requires a DevEco Studio
  installation; it fails on a CLT-only machine. Use `harmonyos` MCP + the
  `devecocli` CLI.
- **ArkTS object literal**: `let x = { a: 1 }` fails if the target type is not
  explicit. Declare `class`/`interface` and annotate.
- **`@Prop` deep copy**: large objects in V1 `@Prop` are copied; use
  `@ObjectLink`/V2 `@Param` with an `@ObservedV2` model.
- **Page not registered**: a new page must be added to `main_pages.json` or
  routing silently fails.
- **Resource missing**: `$r('app.string.foo')` fails at build time if the key is
  absent from `base` and the active qualifier.
- **Emulator hdc**: wrong port range, stale hdc server, or WSL2 owning the
  default `8710`; set `OHOS_HDC_SERVER_PORT=18710`, use device target
  `127.0.0.1:15000`, and check `Emulator.log`.
- **Signing**: a HAP signed with a different key cannot replace an installed
  app; uninstall or sign consistently.
- **`setWindowLayoutFullScreen(true)` + HDS**: manual fullscreen collapses the
  HDS title bar's custom node to 17 vp and its buttons to 9 vp. Use
  `.ignoreLayoutSafeArea` on the HDS container instead, and clear the title-bar
  band with `padding`, never `Blank()`.
- **`expandSafeArea` on the wrong node**: the status bar / gesture bar keep
  showing the window background unless the node that *paints* the background
  expands. Expanding the wrapper `Stack` leaves the gradient child at its
  unexpanded size, so nothing changes; expanding the shell/root `Stack` drags
  `Navigation` with it and breaks `TITLE_BAR_CLEARANCE`. Put
  `.expandSafeArea([SYSTEM], [TOP, BOTTOM])` on the decorative background layer
  (and on a `NavDestination`'s own coloured `Column`), never on a layout container.
- **Double status-bar inset in `NavDestination`**: the content root already starts
  at the status-bar bottom, so adding `padding({ top: 40 })` (as the removed
  `EditorPage` did with `height(96)`) only pushes the header down — the "header
  下沉" defect. `TrashPage` had the same bug with `top: 48`. A page header is a
  plain 56 vp row.
- **Half-immersed `NavDestination`**: a page that sets `backgroundColor(page_bg)`
  but expands only `SafeAreaEdge.BOTTOM` still shows the window background in the
  status-bar band. In light mode this is nearly invisible (`#F5F6F8` vs a
  near-white window), so it ships unnoticed and only shows up in dark mode as a
  black band above the page. Use the two-layer backdrop-plus-content `Stack` and
  check dark mode by sampling `(20, y)` for small `y`.
- **Discarding an untouched 新建笔记 by byte comparison**: the body is normalised
  on the way in and out, so `'# 无标题\n\n'` comes back as `'# 无标题'` and every
  fresh note looks edited — the mis-tap discard then never fires, silently. Test
  emptiness semantically (strip the auto H1 + whitespace), and require *both*
  "created from `+` this visit" and "never edited" so a real note is never
  purged. Use `purgeNote()`, not `deleteNote()` — a mis-tap belongs in neither
  the list nor 回收站.
- **`HdsTabs` requires API ≥ 23**: guard with `deviceInfo.sdkApiVersion` and keep
  a non-HDS `PlainShell()` fallback; never call HDS APIs unguarded.
- **`stateStyles({...})`**: rejected by this toolchain in both forms (inline
  attribute object literal and `@Styles` function reference). Use
  `.clickEffect()` / `.hoverEffect()` for press feedback.
- **A `@Builder` argument is not a state dependency.** Passing
  `this.davRowSubtitle()` into `SettingRow(...)` evaluated the `@Local` once at
  the call site; reassigning the field never reached the built `Text`, so the
  设置 › WebDAV 同步 row showed pre-sync text on device even though `didShow`
  had already updated the value. Read runtime state inside a parameter-less
  builder (`Index.WebDavRow()`), or use `@ComponentV2` + `@Param`.
- **`WaterFlow` width**: a `FlowItem`'s child is measured against the whole flow,
  so percentage widths bleed into the neighbouring column. Give cells an explicit
  computed width, and never put a full-width header inside a multi-column flow.
- **Driving a `TextArea` through `uinput`/`uiInput` is brittle, and `$` needs shell
  quoting care.** `harmonyos_input_text` (and `uitest uiInput text`) types into the
  focused field, but PowerShell mangles `$` before hdc ever sees it — an unquoted
  `$E` was expanded away and `$$` arrived as a PID (`17021`). Wrap the whole command
  in single quotes and escape `$` with a backtick when building it in PowerShell.
  `KEYCODE_ENTER` (2054) is swallowed by the IME — it commits the composition rather
  than inserting a break, so use `keyEvent 2055` (DEL) to clear instead of
  select-all-delete. Verify the result by `cat`-ing the `.md` over hdc: the rendered
  view hides quoting damage that the source keeps. Prefer fixing the template in
  `NoteStore.createSample()` and reinstalling over hand-editing a live note.
- **The app sandbox is not writable from `hdc`.** `shell` runs as uid 2000; the
  notes dir is uid 20020064 with `-rw-rw----`, so `ls`/`rm`/`cat` work but
  `echo >`, `cp`, and `file send` return `Permission denied`. `/data/local/tmp`
  is writable. To change note content, drive the UI or reinstall — do not assume
  you can patch the `.md` files directly. (`rm` on a file inside `notes/` does
  work because the directory itself is `drwxrwxrwx`; that is the only escape
  hatch, and it edits the collection out from under the app's index.)
- **WebDAV: do not rebuild the baseline from local state.** See §6 *WebDAV sync*.
  Writing `note.updatedAt` for every local note after a run — including notes
  whose PUT failed — makes the next run read the stale remote file, classify it
  as "the remote changed", and overwrite the newer local body. Reproduced on the
  emulator with the user's own vault shape. Only server-confirmed operations may
  advance the baseline, and a failed remote GET must abort the run outright.
- **WebDAV: `zhijian/a.md` is not `a.md`.** `WebDavClient` speaks paths relative
  to the base URL and `Note.relPath` is a bare filename. Any comparison across
  the two without `SyncEngine.localRel()` makes every note look renamed, and the
  whole vault is re-uploaded on each sync (observed: `upload=16` on every run,
  forever, with `lc=false rc=false` for every note).
- **WebDAV: one id, one remote path.** A rename leaves the old remote file
  behind; the id then names two bodies and they flip on every sync — this is the
  path that silently rolled a note back to an older body. Clean up every other
  path for an id this run pushed, but only when the local filename provably
  exists remotely, otherwise the cleanup deletes the file it just read from.
- **WebDAV: a conflict copy needs the mark in its H1.** The note list renders
  `note.title`, which `reload()` re-derives from the body's H1, so a filename-only
  `(冲突 HHmm)` leaves two indistinguishable cards — and the first edit through
  the editor renames the file back and erases the mark entirely.
- **WebDAV: `500 Connection established` is the proxy's tunnel status.** Behind a
  CONNECT proxy RCP can surface the failed CONNECT as a 500 with that reason
  phrase; `curl` against the same URL succeeds every time. Retry (all verbs used
  here are idempotent for the same body) instead of treating it as an origin
  error.
- **WebDAV: a deletion is only confirmed when it provably happened.** Two
  independent halves, both learned the hard way: `NoteStore.deleteNote()` returns
  whether the file reached `.trash`, and `trashRemote()` returns true only when
  *every* path for the id was trashed. Dropping the baseline row on a failed
  attempt makes the next run read the surviving file as "new from another
  device" and download the note the user just deleted. Never infer "deleted" from
  `ok` on the transport call alone.
- **WebDAV: the baseline belongs to one server.** `syncBaseScope`
  (`<baseUrl>\t<username>`) is written with it and checked before use. Reusing a
  baseline after changing the URL makes every note look deleted remotely — one
  tap from trashing the entire vault.
- **WebDAV: never read "the id is gone" as "the note is gone".** A hand-edited or
  externally rewritten `.md` can keep its path and lose its `id:` line. Identity
  is recovered from the baseline path (`baseByPath`) before the merge, in both
  directions; an id-only test either trashes a live note or imports a duplicate.
  Never "repair" the frontmatter by re-uploading this device's body over the
  remote one — that rolls the remote text back.
- **Do not verify a sync by deleting test notes through the grid.** A long-press
  then delete re-flows the `WaterFlow`, so the second long-press in the same spot
  hits a *different* card — it deleted a real 无标题 note during this work. Delete
  test fixtures from the WebDAV side (`curl -X DELETE`) and leave the grid alone,
  or re-read `ui_dump` bounds before every long-press. The same rule now applies
  to testing deletion propagation: delete on the *server* (or via a note you
  created for the purpose) and let the next sync move the local copy to 回收站.
