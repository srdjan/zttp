// Orders service handler
import { cacheGet } from "zttp:cache";
import { routerMatch } from "zttp:router";

structural Guardrails<T> = Proof<T,
    | "injection_safe"
    | "state_isolated"
    | "no_secret_leakage"
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
