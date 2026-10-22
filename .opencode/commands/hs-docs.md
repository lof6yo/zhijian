---
description: Search official HarmonyOS docs and answer with API 26 specifics
agent: harmonyos
---

Research `$ARGUMENTS` using the official sources:

1. MCP `harmonyos-knowledge` → `searchDocuments` (topK 5), then
   `getDocumentsById` for the best 1–3 `parent` results.
2. If MCP is unavailable, `devecocli docs search $ARGUMENTS` and
   `devecocli docs read <id>`.
3. If still ambiguous, inspect the local SDK `.d.ts` under
   `D:\deveco\command-line-tools\sdk\default\openharmony\ets`.

Answer with: the recommended API 26 approach, exact imports/signatures, a
minimal code sketch, pitfalls/deprecations, and the doc IDs/URLs used. Do not
write project code unless asked. $ARGUMENTS
