---
description: Build the HarmonyOS HAP and fix the first error
agent: harmonyos
---

Build the project:

```powershell
devecocli build
```

If the build fails, read only the first error, explain it in one line, fix it,
and rebuild. Repeat until `BUILD SUCCESSFUL`. Report the artifact path (the
`Build artifacts:` line) and any remaining warnings. Do not modify generated
output under `entry/build/`, `.hvigor/`, or `oh_modules/`. $ARGUMENTS
