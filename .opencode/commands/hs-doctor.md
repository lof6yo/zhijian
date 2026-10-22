---
description: Run the environment/toolchain/MCP doctor
agent: harmonyos
---

Run the doctor script and report the result:

```powershell
pwsh -NoProfile -File scripts\doctor.ps1
```

If a check fails, explain the exact missing tool/path and the smallest safe fix.
Do not install global packages, log in to Huawei, or modify signing material
without asking. $ARGUMENTS
