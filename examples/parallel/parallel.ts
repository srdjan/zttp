import { parallel } from "zttp:io";
import { jwtVerify } from "zttp:auth";
import { env } from "zttp:env";
import { fetch } from "zttp:fetch";

structural Guardrails<T> = Proof<T,
  | "state_isolated"
  | "fault_covered"
  | "result_safe"
  | "optional_safe"
  | "canonical"
  | "cost_bounded"
>;

function handler(req: Request): Guardrails<Response> {
  const token = req.headers.get("authorization");
  const secret = env("JWT_SECRET");
  if (secret === undefined) {
    return Response.json({ error: "server misconfigured" }, { status: 500 });
  }

  const auth = jwtVerify(token, secret);
  if (!auth.ok) return Response.json({ error: "unauthorized" }, { status: 401 });

  function _fetchUser(): unknown {
    return fetch("https://users.internal/api/v1/me", {});
  }

  function _fetchOrders(): unknown {
    return fetch("https://orders.internal/api/v1/recent", {});
  }

  function _fetchRecommendations(): unknown {
    return fetch("https://ml.internal/api/v1/recommendations", {});
  }

  // Three API calls concurrently - ~50ms instead of ~150ms
  const results = parallel([
    _fetchUser,
    _fetchOrders,
    _fetchRecommendations
  ]);
  const user = results[0];
  const orders = results[1];
  const recommendations = results[2];

  let userPayload: unknown = undefined;
  if (user.ok) {
    userPayload = user.json();
  }
  let ordersPayload: unknown = { items: [] };
  if (orders.ok) {
    ordersPayload = orders.json();
  }
  let recommendationsPayload: unknown = [];
  if (recommendations.ok) {
    recommendationsPayload = recommendations.json();
  }

  return Response.json({
    user: userPayload,
    orders: ordersPayload,
    recommendations: recommendationsPayload
  });
}
