// Match expression handler example
//
// Demonstrates using match for HTTP routing.

import { match } from "zttp:core";
import { env } from "zttp:env";

function handler(req: Request): Response {
  return match(req)
    .with(
      { method: "GET", path: "/health" },
      () => Response.json({ ok: true }),
    )
    .with(
      { method: "GET", path: "/version" },
      () => Response.json({ version: "1.0.0" }),
    )
    .with(
      { method: "POST", path: "/echo" },
      () => Response.json(req.body),
    )
    .otherwise(() => Response.text("Not Found", { status: 404 }));
}
