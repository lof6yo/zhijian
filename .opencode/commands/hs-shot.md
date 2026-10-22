---
description: Capture an emulator screenshot and review the UI
agent: harmonyos
---

Capture the current emulator screen:

```powershell
New-Item -ItemType Directory -Force screenshots | Out-Null
devecocli ui screenshot --path screenshots\screen.png
```

Then read `screenshots\screen.png` and check: expected screen, no blank view,
no clipped/overlapping text, readable dark mode (if active), and visible
loading/error/empty states. Describe concrete visual issues with locations, and
fix them if the user asked for UI work. Use MCP `harmonyos.screenshot` if the
CLI is unavailable. $ARGUMENTS
