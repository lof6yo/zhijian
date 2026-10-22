---
name: HarmonyOS App Engineering
description: Design and implement native HarmonyOS NEXT features with ArkTS/ArkUI API 26 — architecture, state management V2, Navigation, resources/dark mode, permissions, data, concurrency, and performance. Use for any non-trivial feature, refactor, or UI work in this repo.
---

# HarmonyOS App Engineering

Use this skill when the task is more than a one-line fix: a new page, a data
flow, a native capability, a refactor, or a UI that must feel like HarmonyOS.

Read `AGENTS.md` first. This skill assumes API 26, Stage model, and the
`entry` HAP layout in this repo.

## 1. Architecture decision

Start with the smallest structure that can survive the next feature:

| Situation | Structure |
|---|---|
| One app, one entry, a handful of pages | Single `entry` HAP with `pages/components/viewmodels/models/services/common` layers. **Current default.** |
| Shared code between two HAPs, or a publishable library | Extract a `har` module; depend on it from `entry`. |
| Shared runtime UI/resources between HAPs, or large assets | Use an `hsp` module; load it as a shared package. |
| Independent feature owned by a team | A `feature` HSP/HAR + a thin entry shell; agree on the navigation contract first. |

Do not create a new module just to look “architected”. A clean single HAP with
a one-way dependency graph is better than premature HSP/HAR boundaries.

Dependency direction:

```text
pages ──► components
  │           │
  └──► viewmodels ──► services ──► models
                         │
                         └──► common (no UI imports)
```

- `models/` — plain classes/interfaces/enums; serializable; no UI imports.
- `services/` — network, preferences, RDB, files, platform kits.
- `viewmodels/` — `@ObservedV2` state + actions; no `build()`.
- `components/` — reusable, stateless where possible; inputs via `@Param`,
  outputs via `@Event`.
- `pages/` — composition + lifecycle only.

## 2. State management V2

Use V2 consistently in new code.

```ts
// models/Todo.ets
@ObservedV2
export class Todo {
  readonly id: string;
  @Trace title: string;
  @Trace done: boolean;

  constructor(id: string, title: string, done: boolean = false) {
    this.id = id;
    this.title = title;
    this.done = done;
  }
}

// viewmodels/TodoStore.ets
@ObservedV2
export class TodoStore {
  @Trace items: Todo[] = [];

  add(title: string): void {
    this.items = [...this.items, new Todo(crypto.randomUUID(), title)];
  }

  toggle(id: string): void {
    const item = this.items.find((t: Todo) => t.id === id);
    if (item) {
      item.done = !item.done; // @Trace field mutation
    }
  }
}

// components/TodoRow.ets
@ComponentV2
export struct TodoRow {
  @Param todo: Todo = new Todo('', '');
  @Event onToggle: (id: string) => void = () => {};

  build() {
    Row({ space: 12 }) {
      Checkbox({ name: this.todo.id })
        .select(this.todo.done)
        .onChange(() => this.onToggle(this.todo.id))
      Text(this.todo.title)
        .fontSize(16)
        .textDecoration(this.todo.done ? TextDecorationType.LineThrough : TextDecorationType.None)
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
  }
}
```

Rules:

- `@Local` — component-owned state.
- `@Param` — immutable input; never assign to it. Use `@Event` to request changes.
- `@ObservedV2` + `@Trace` — shared mutable model. Mutate `@Trace` fields or
  reassign arrays/maps.
- `@Provider`/`@Consumer` — pass a store through a deep tree without prop drilling.
- `PersistenceV2.connect(Type, () => new Type())` — small persistent UI state.
  Use `?? new Type()` to handle the `undefined` return.
- `AppStorageV2.connect` — in-memory app-wide state; do not use it for secrets.
- Do not mix V1 (`@State`, `@Prop`, `@Link`, `@Observed`, `@ObjectLink`) and V2
  decorators in the same component tree unless you are deliberately using
  `UIUtils.enableV2Compatibility`.

## 3. Navigation

Use `Navigation` + `NavPathStack` + `NavDestination`. Do not add `router` calls.

```ts
// pages/Index.ets
@Entry
@ComponentV2
struct Index {
  @Local pathStack: NavPathStack = new NavPathStack();

  @Builder
  pageMap(name: string) {
    if (name === 'detail') {
      DetailPage()
    } else if (name === 'settings') {
      SettingsPage()
    }
  }

  build() {
    Navigation(this.pathStack) {
      HomePage()
    }
    .navDestination(this.pageMap)
    .mode(NavigationMode.Stack)
    .title('HMStart')
    .hideTitleBar(false)
  }
}

// pages/DetailPage.ets
@ComponentV2
export struct DetailPage {
  @Local itemId: string = '';

  build() {
    NavDestination() {
      Column({ space: 16 }) {
        Text(`Item: ${this.itemId}`).fontSize(20)
      }
      .padding(24)
      .width('100%')
      .height('100%')
    }
    .title('详情')
    .onReady((ctx: NavDestinationContext) => {
      this.itemId = (ctx.pathInfo.param as string) ?? '';
    })
  }
}
```

Push with a typed param:

```ts
this.pathStack.pushPath({ name: 'detail', param: todo.id });
```

Rules:

- Register every `@Entry` page in `resources/base/profile/main_pages.json`.
- Use one root `Navigation` per page; nested `Navigation` only for split flows.
- Keep `NavPathStack` in the page or a `@Provider`; don’t use a global mutable
  singleton for routing.
- On wide screens, use `NavigationMode.Auto`/`Split` and test the back stack.
- For tabs, put the `Tabs` inside the `Navigation` content, not the reverse.

## 4. Layout, responsive, dark mode

- Use `Column`/`Row`/`Stack`/`Flex` first; `RelativeContainer` only for complex
  overlap; `GridRow`/`GridCol` for responsive grids.
- Breakpoints via `GridRow` (sm/md/lg) or `mediaquery`; don’t hardcode widths.
- Use `layoutWeight(1)` and `constraintSize` instead of fixed heights.
- Respect safe areas: `expandSafeArea` for immersive backgrounds, padding for
  content; test with the status/navigation bars.
- Long lists: `List` + `LazyForEach` with a stable key + `cachedCount`; use
  `@Reusable` for expensive rows.
- Dark mode: every custom color needs a `resources/dark/element/color.json`
  entry. Prefer `$r('app.color.*')` or system colors (`$r('sys.color.*')`).
- Typography: `fp` for text, `vp` for spacing; support font scaling; avoid
  fixed-height text containers.
- Motion: use `animateTo`/`curves` for state changes; keep durations 150–300 ms;
  avoid animating layout properties in long lists.

## 5. Resources and strings

```json
// resources/base/element/string.json
{ "string": [ { "name": "home_title", "value": "首页" } ] }

// resources/base/element/color.json
{ "color": [ { "name": "page_bg", "value": "#F2F3F5" } ] }

// resources/dark/element/color.json
{ "color": [ { "name": "page_bg", "value": "#101010" } ] }
```

- Use `$r('app.string.home_title')`, `$r('app.color.page_bg')`.
- Add `en_US`/`zh_CN` qualifiers only when the app is localized; keep `base` as
  the default.
- Media: use `resources/base/media/*`; provide dark variants only if the asset
  itself must change.
- Never concatenate user-facing sentences from fragments; use a single string
  with placeholders (`%s`/`%d`) in resources.

## 6. Data and persistence

Choose the lightest store that fits:

| Need | Use |
|---|---|
| A few settings/flags | `preferences` |
| Relational/queryable data | RDB (`@kit.ArkData`, `relationalStore`) |
| Observable app state that survives restart | `PersistenceV2` (small, UI-shaped) |
| Secrets/tokens | Asset Store Kit (`@kit.AssetStoreKit`) |
| Large files/images | App sandbox files + `fileIo`/`filePicker` |

`preferences` sketch:

```ts
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

export class SettingsService {
  private store: preferences.Preferences | null = null;

  async init(context: common.UIAbilityContext): Promise<void> {
    this.store = await preferences.getPreferences(context, 'settings');
  }

  async getTheme(): Promise<string> {
    return (await this.store?.get('theme', 'system')) as string;
  }

  async setTheme(value: string): Promise<void> {
    await this.store?.put('theme', value);
    await this.store?.flush();
  }
}
```

RDB rules: parameterized SQL (`?`), explicit schema version + migrations,
close result sets, do writes off the UI thread when large.

Asset Store rules: alias-based, `DEVICE_FIRST_UNLOCKED` for background use,
never log the secret, handle `NOT_FOUND`/`DUPLICATED`.

## 7. Permissions

Declare in `module.json5`:

```json5
"requestPermissions": [
  {
    "name": "ohos.permission.INTERNET"
  },
  {
    "name": "ohos.permission.APPROXIMATELY_LOCATION",
    "reason": "$string:location_reason",
    "usedScene": { "abilities": ["EntryAbility"], "when": "inuse" }
  }
]
```

Request at the point of use:

```ts
import { abilityAccessCtrl, common } from '@kit.AbilityKit';

async function ensureLocation(context: common.UIAbilityContext): Promise<boolean> {
  const atManager = abilityAccessCtrl.createAtManager();
  const result = await atManager.requestPermissionsFromUser(
    context, ['ohos.permission.APPROXIMATELY_LOCATION']);
  return result.authResults.every((code: number) => code === 0);
}
```

- `INTERNET` is system-granted; still declare it.
- Runtime permissions: handle denial and “don’t ask again”; provide a settings
  entry (`want` to app settings) when needed.
- Never request a permission you don’t use; reviewers reject it.

## 8. Network and concurrency

```ts
import { http } from '@kit.NetworkKit';

export class ApiClient {
  async getJson(url: string): Promise<string> {
    const client = http.createHttp();
    try {
      const res = await client.request(url, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 10000,
        readTimeout: 10000,
        header: { 'Accept': 'application/json' }
      });
      if (res.responseCode < 200 || res.responseCode >= 300) {
        throw new Error(`HTTP ${res.responseCode}`);
      }
      return res.result as string;
    } finally {
      client.destroy();
    }
  }
}
```

- Never block the UI thread with parsing/large IO. Use `taskpool`:

```ts
@Concurrent
function parseLarge(text: string): string {
  return text.trim(); // only imports/locals inside @Concurrent
}

const result = await taskpool.execute(parseLarge, payload);
```

- `@Concurrent` functions cannot capture component state or closures; pass
  serializable arguments.
- Use `systemDateTime.getTime()` for persisted timestamps, not `Date.now()`.
- Cancel/ignore stale requests when the page disappears.

## 9. Common ArkTS compile errors

| Error | Fix |
|---|---|
| `arkts-no-any-unknown` | Give a concrete type; use `Object` only at a real boundary and narrow immediately. |
| `arkts-no-untyped-obj-literals` | Declare a `class`/`interface` and annotate the variable. |
| `arkts-no-props-by-index` | Use explicit fields or `Map<string, T>`. |
| `arkts-no-func-apply-bind` | Call the function directly; pass a typed closure. |
| `arkts-no-definite-assignment` | Initialize fields or use a constructor. |
| `Property 'x' does not exist` | Check API 26 signature/import; the method may be on a kit or a newer API. |
| `Failed to resolve module` | Add the dependency to `oh-package.json5`, run `devecocli build` (ohpm install). |
| `Page not found` | Add the page to `main_pages.json`. |
| `Resource not found` | Add the key to `base` (and `dark` if a color) or fix the `$r` name. |

## 10. Review checklist

- [ ] One-way dependencies; no UI imports in `models`/`services`.
- [ ] V2 state only in new components; no `@Param` mutation.
- [ ] Navigation/back stack works; params typed; no `router`.
- [ ] No hardcoded user-facing strings/colors; dark mode checked.
- [ ] Responsive at phone and wide widths; safe areas respected.
- [ ] Permissions minimal and requested at use; denial handled.
- [ ] Secrets in Asset Store, not source/preferences/logs.
- [ ] Lists lazy; no heavy work in `build()`; `@Concurrent` constraints respected.
- [ ] Build/check/launch/screenshot verified.

## References

- `references/arkts-rules.md` — stricter ArkTS patterns and anti-patterns.
- `references/ui-patterns.md` — Navigation, tabs, lists, forms, dialogs,
  responsive and accessibility recipes.
- `references/data-security.md` — preferences/RDB/PersistenceV2/Asset Store,
  network and permission details.
- `references/review-checklist.md` — a compact review checklist to paste into a PR.
