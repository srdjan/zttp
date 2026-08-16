---
name: route-table
description: Add a `zttp:router` route table to an existing handler.
---
Add routing to the handler using `zttp:router`:
1. Read the target file. Run `zts_expert_verify_paths`. Gather current module facts with `zts_expert_query` operation `modules`.
2. Author the COMPLETE file content yourself for every changed path and submit exactly one `propose_change_set` call. The host proves the aggregate draft before the approval policy can commit it.
3. Import `routerMatch` from `zttp:router`. Check the optional match with `if (found !== undefined)`.
4. Keep each handler signature explicit.

Route-table shape:
```ts
import { routerMatch } from "zttp:router";

function getIndex(req: Request): Response {
  return Response.json({ ok: true });
}

const routes = {
  "GET /": getIndex,
};

function handler(req: Request): Response {
  const found = routerMatch(routes, req);
  if (found !== undefined) {
    req.params = found.params;
    return found.handler(req);
  }
  return Response.json({ error: "not_found" }, { status: 404 });
}
```

Each route handler receives `(req)`. Read path parameters from `req.params`. Path parameters use `:name` syntax.
