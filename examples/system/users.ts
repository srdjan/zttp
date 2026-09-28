// Users service handler with author-declared proof obligations.
import { cacheGet, cacheSet } from "zttp:cache";
import { routerMatch } from "zttp:router";
import { serviceCall } from "zttp:service";

// The capsule claims only what this handler can hold. It does not claim
// no_secret_leakage: getUserById returns a value read back from the cache, and
// a cache read carries unknown provenance, because the read cannot see what an
// earlier write stored there. It does not claim injection_safe: the route
// parameter `id` reaches the orders service query unvalidated.
structural Guardrails<T> = Proof<T,
    | "state_isolated"
>;

function getUserById(req: Request): Response {
  const id = req.params.id;
  // Check cache first
  const cached = cacheGet("users", id);
  if (cached !== undefined) {
    return Response.json({ user: cached });
  }

  // Fetch from orders service
  const orders = serviceCall("orders", "GET /api/orders", {
    query: { userId: id },
  });
  if (orders.status !== 200) {
    return Response.json({ error: "orders unavailable" }, { status: 502 });
  }

  const user = { id: id, name: ["User ", String(id)].join(""), orders: orders.json() };

  cacheSet("users", id, JSON.stringify(user), 300);
  return Response.json({ user: user });
}

function listUsers(req: Request): Response {
  return Response.json({ users: [] });
}

const routes = {
  "GET /api/users/:id": getUserById,
  "GET /api/users": listUsers,
};

function handler(req: Request): Guardrails<Response> {
  const found = routerMatch(routes, req);
  if (found !== undefined) {
    req.params = found.params;
    return found.handler(req);
  }
  return Response.json({ error: "not found" }, { status: 404 });
}
