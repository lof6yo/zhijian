# Data, Network, and Security

## Decision table

| Need | API | Notes |
|---|---|---|
| Small settings/flags | `preferences` (`@kit.ArkData`) | Async; call `flush()` after writes. |
| Relational/queryable data | `relationalStore` RDB (`@kit.ArkData`) | Parameterized SQL; version + migrations. |
| Observable app state that survives restart | `PersistenceV2` | Small, UI-shaped; `@ObservedV2` + `@Trace`. |
| Secrets/tokens | Asset Store Kit (`@kit.AssetStoreKit`) | Alias-based; never log. |
| Large files/images | App sandbox + `fileIo`/pickers | Don’t request broad storage permissions. |

## preferences

```ts
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

const store = await preferences.getPreferences(context, 'settings');
await store.put('theme', 'dark');
await store.flush();
const theme = await store.get('theme', 'system') as string;
```

- Use a small number of keys; don’t store JSON blobs of unbounded size.
- Handle `BusinessError`; a failed flush should be logged and surfaced if the
  setting is critical.
- Don’t store tokens/passwords here.

## RDB

- Define a schema version; migrate with explicit `ALTER TABLE` steps.
- Use `?` placeholders:

```ts
const predicates = new relationalStore.RdbPredicates('todo');
predicates.equalTo('id', id);
await store.update(values, predicates);
```

- Read into typed models; close `ResultSet` in `finally`.
- Batch writes in a transaction for imports; don’t do thousands of individual
  writes on the UI thread.
- Test migration from the previous schema, not only a fresh install.

## PersistenceV2

```ts
@ObservedV2
export class AppSettings {
  @Trace theme: string = 'system';
  @Trace compact: boolean = false;
}

export const appSettings: AppSettings =
  PersistenceV2.connect(AppSettings, () => new AppSettings()) ?? new AppSettings();
```

- Only `@Trace` fields trigger UI updates; persist small objects/collections.
- Don’t persist UI objects, `PixelMap`, `Want`, or secrets.
- Call `PersistenceV2.save(Type)` after batched non-`@Trace` changes if needed.
- Treat the persisted shape as a schema; add defaults for new fields.

## Asset Store Kit

```ts
import { asset } from '@kit.AssetStoreKit';

const attr: asset.AssetMap = new Map();
attr.set(asset.Tag.ALIAS, 'api_token');
attr.set(asset.Tag.SECRET, '...');
attr.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
await asset.add(attr);
```

- Use a stable alias; query/update/remove by alias.
- Handle `NOT_FOUND` and `DUPLICATED` explicitly.
- Never log the secret or put it in a crash report.
- Clear on logout; consider `DEVICE_FIRST_UNLOCKED` only when background access
  is genuinely required.

## Network

- `@kit.NetworkKit` `http.createHttp()`; set connect/read timeouts.
- Check `responseCode`; parse only after a 2xx.
- Add `Accept`/`Content-Type`; don’t log `Authorization`.
- Handle cancellation/page disappearance; ignore stale responses.
- For streaming, use `requestInStream` + `on('dataReceive')`; decode UTF-8 with
  `util.TextDecoder` incrementally.
- Declare `ohos.permission.INTERNET`.

## Permissions

- Declare only what you use, with `reason` and `usedScene`.
- Request runtime permissions at the point of use; handle denial.
- If “don’t ask again”, guide the user to app settings via a `Want`.
- Test denial paths, not just the grant path.

## Files

- Use `context.filesDir`/`cacheDir` for app-private data.
- Use `filePicker`/`photoAccessHelper` for user files; avoid broad storage
  permissions.
- Sanitize file names; never concatenate untrusted paths.
- Clean cache on low storage; don’t delete user documents.

## Logging

- `hilog` with `DOMAIN = 0x0000`, `TAG = 'HMStart'`.
- Log IDs, counts, and error codes; never tokens, full URLs with query secrets,
  or user content.
- Use `%{public}s` only for non-sensitive values; otherwise use `%{private}s`.
