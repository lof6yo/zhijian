# ArkTS Strict-Mode Rules and Patterns

ArkTS is a TypeScript-derived, statically typed language with restrictions. The
compiler (not just lint) rejects many JS/TS patterns. Treat these as hard rules.

## Types

- No `any`, no `unknown` in app code. Use a concrete type or a narrow union.
- No untyped object literals. Declare a `class` or `interface`:

```ts
// bad: let p = { x: 1, y: 2 };
interface Point { x: number; y: number; }
let p: Point = { x: 1, y: 2 }; // OK: target type is explicit
```

- No index signatures (`[key: string]: T`) on classes/interfaces. Use
  `Map<string, T>` or explicit fields.
- No structural typing assumptions. A class instance is not interchangeable
  with a plain object of the same shape; use a constructor/`fromJson`.
- Avoid `as` casts except at real boundaries (JSON, platform results); narrow
  with a type guard immediately.
- `Object` is allowed only at boundaries; convert to a typed model at once.
- Prefer `readonly` for IDs and immutable fields.
- Initialize all fields (or assign in the constructor); no definite-assignment
  `!` on fields.

## Functions and objects

- No `Function.apply`, `Function.call`, `Function.bind`, `eval`, `new Function`.
- No prototype manipulation (`Object.setPrototypeOf`, `__proto__`).
- No `Object.defineProperty`/`Object.freeze` for app state.
- No `delete` on class fields; model optional state explicitly.
- No `arguments`; use rest parameters (`...args: T[]`).
- No getters/setters that hide expensive work; use methods.

## Modules and imports

- Import from `@kit.*` or `@ohos.*`; do not deep-import SDK internals.
- Use `.ets` for UI/ArkTS files; `.ts` only for pure logic that the toolchain
  accepts. Prefer `.ets` in this project.
- No circular imports; move shared types to `models/`.
- No `require`; use ES imports.

## UI component rules

- `build()` is declarative: no `await`, no network, no heavy loops, no mutation
  of state that triggers another render in the same pass.
- Do not create components in a loop without keys; use `ForEach`/`LazyForEach`
  with a stable key.
- Do not use `@State`/`@Prop`/`@Link` in a `@ComponentV2`; use V2 decorators.
- `@Param` is read-only; emit changes through `@Event`.
- `@Builder` functions are synchronous; no `async`.
- `@Concurrent` functions: top-level, only imports/local variables, arguments
  and return values must be serializable (no UI objects, no closures).

## Error handling

```ts
import { BusinessError } from '@kit.BasicServicesKit';

try {
  await doWork();
} catch (e) {
  const err = e as BusinessError;
  hilog.error(0x0000, 'HMStart', 'doWork failed: %{public}d %{public}s',
    err.code, err.message);
}
```

- Do not `catch {}` silently.
- Do not log full payloads/tokens; log IDs and error codes.
- Convert platform errors to a user-facing message at the page/view-model layer.

## Time and numbers

- Persisted timestamps: `systemDateTime.getTime()` (milliseconds), not
  `Date.now()`.
- Money: integer minor units or a decimal library; never binary floats for
  currency.
- Large integers from JSON: validate range before use.

## Serialization

- `JSON.parse` returns `Object`; immediately map to a typed model:

```ts
interface UserDto { id: string; name: string; }
class User {
  id: string = '';
  name: string = '';
  static fromJson(raw: string): User {
    const dto = JSON.parse(raw) as UserDto;
    const u = new User();
    u.id = dto.id;
    u.name = dto.name;
    return u;
  }
}
```

- Validate required fields and types; don’t trust network data.
- Avoid `JSON.stringify` on UI objects/`PixelMap`/`Want`.

## Anti-patterns

| Anti-pattern | Better |
|---|---|
| `let data: any = await res.json()` | `const dto = JSON.parse(text) as MyDto` + map |
| `obj['field']` | explicit field or `Map` |
| `setTimeout` for UI sync | state + `animateTo`/`onAreaChange` |
| `@Prop` on a large object | `@ObjectLink` (V1) or V2 `@Param` with `@ObservedV2` |
| `router.pushUrl` | `Navigation` + `NavPathStack` |
| hardcoded `#FFFFFF` | `$r('app.color.*')` + dark variant |
| `console.log` | `hilog` with domain/tag |
| network in `build()` | view-model method + loading state |
