// Explicit guard flow
// Each guard answers a Response to refuse the request, or undefined to let it
// through. The handler runs them in order and returns the first refusal.

import { routerMatch } from "zttp:router";
import { env } from "zttp:env";
import { parseBearer, jwtVerify } from "zttp:auth";

function preflight(req: Request): Response | undefined {
  if (req.method === "OPTIONS") {
    return Response.text("", {
      status: 204,
      headers: {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "GET, POST",
        "Access-Control-Allow-Headers": "Authorization, Content-Type",
      },
    });
  }
}

function requireAuth(req: Request): Response | undefined {
  const header = req.headers["authorization"] ?? "";
  const token = parseBearer(header);
  if (token === undefined) return Response.json({ error: "unauthorized" }, { status: 401 });
  const secret = env("JWT_SECRET");
  if (
    secret === undefined
  ) return Response.json({ error: "server misconfigured" }, { status: 500 });

  const result = jwtVerify(token, secret);
  if (!result.ok) return Response.json(
    { error: result.error },
    { status: 403 },
  );
}

// Route handlers
function getHealth(req: Request): Response {
  return Response.json({ healthy: true });
}

function getUser(req: Request): Response {
  return Response.json({ id: req.params.id });
}

const routes = { "GET /health": getHealth, "GET /users/:id": getUser };

function routeHandler(req: Request): Response {
  const found = routerMatch(routes, req);
  if (found !== undefined) {
    req.params = found.params;
    return found.handler(req);
  }
  return Response.json({ error: "Not Found" }, { status: 404 });
}

// preflight -> auth -> routes
function handler(req: Request): Response {
  const preflighted = preflight(req);
  if (preflighted !== undefined) {
    return preflighted;
  }
  const refused = requireAuth(req);
  if (refused !== undefined) {
    return refused;
  }
  return routeHandler(req);
}
