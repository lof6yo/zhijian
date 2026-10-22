---
description: Inspect recent app error/crash logs and identify the root cause
agent: harmonyos
---

Collect recent logs for this app:

```powershell
devecocli log --level E --from 5m --tail 200
devecocli log --crash --bundle-name com.hmprojects.hmstart
```

Group the output by error signature, identify the first app-owned frame, and
state the likely root cause with `file:line`. If the app restarted, check the
crash log first. Do not paste the entire log; quote only the relevant 5–15
lines. $ARGUMENTS
