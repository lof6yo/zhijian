---
description: Dump the current UI tree and summarize interactive nodes
agent: harmonyos
---

Dump the current UI:

```powershell
devecocli ui layout --format json --mode simplified > ui-layout.json
devecocli ui window list --format json
```

Summarize the visible page: title, key text, clickable nodes with their ids and
bounds, and anything that looks clipped or missing. Use MCP `harmonyos.ui_dump`
/ `find_ui` if the CLI is unavailable. Do not tap anything yet. $ARGUMENTS
