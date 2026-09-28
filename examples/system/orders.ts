// Orders service handler
import { cacheGet } from "zttp:cache";
import { routerMatch } from "zttp:router";

// The capsule claims only what this handler can hold. It does not claim
// no_secret_leakage: getOrderById returns a value read back from the cache,
// and a cache read carries unknown provenance, because the read cannot see what
// an earlier write stored there.
structural Guardrails<T> = Proof<T,
    | "injection_safe"
    | "state_isolated"
>;

function getOrderById(req: Request): Response {
  const cached = cacheGet("orders", req.params.id);
  if (cached !== undefined) {
    return Response.json({ order: cached });
  }
  return Response.json({ error: "order not found" }, { status: 404 });
}

function listOrders(req: Request): Response {
  return Response.json({ orders: [] });
}

const routes = {
  "GET /api/orders/:id": getOrderById,
  "GET /api/orders": listOrders,
};

function handler(req: Request): Guardrails<Response> {
  const found = routerMatch(routes, req);
  if (found !== undefined) {
    req.params = found.params;
    return found.handler(req);
  }
  return Response.json({ error: "not found" }, { status: 404 });
}
