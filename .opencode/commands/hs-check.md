---
description: Run ArkTS static checks on changed files and fix errors (no build)
agent: harmonyos
---

Run the fast ArkTS check on the files changed in this session (or on
`$ARGUMENTS` if provided):

```powershell
devecocli check arkts $ARGUMENTS
```

If no files are given, use `devecocli check arkts` for the whole project. The
`deveco` MCP is disabled on this CLT-only machine; do not depend on
`deveco.check`. Fix all errors; summarize each error with `file:line` and the
fix. Do not build or run yet.
