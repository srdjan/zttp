---
name: route-table
description: Add a `zttp:router` route table to an existing handler.
---
Add routing to the handler using `zttp:router`:
1. Read the target file. Run `zts_expert_verify_paths`. Gather current module facts with `zts_expert_modules`.
2. Author the COMPLETE file content yourself. Submit exactly one `apply_edit` call. The host compiler veto and approval policy own the write.
3. Import `routerMatch` from `zttp:router`. Check the optional match with `if (match === undefined)`.
4. Keep each handler signature explicit.

Route-table shape:
```ts
import { routerMatch } from "zttp:router";

function handleIndex(req: Request, params: object): Response {
  return Response.json({ ok: true });
}

const routes = {
  "GET /": handleIndex,
};

function handler(req: Request): Response {
  const match = routerMatch(routes, req);
  if (match === undefined) {
    return Response.json({ error: "not_found" }, { status: 404 });
  }
  return match.handler(req, match.params);
}
```

Each route handler receives `(req, params)`. Path params use `:name` syntax.
