// Gateway handler with static fetchSync URLs (for linking demo)
import { env } from "zttp:env";
import { fetch } from "zttp:fetch";
import { serviceCall } from "zttp:service";

structural Guardrails<T> = Proof<T,
    | "injection_safe"
    | "state_isolated"
    | "no_secret_leakage"
>;

function handler(req: Request): Guardrails<Response> {
  const appName = env("APP_NAME") ?? "demo";

  // Named internal call - linked directly to users service
  const health = serviceCall("users", "GET /api/users", {});
  if (!health.ok) {
    return Response.json({ error: "users service down" }, { status: 502 });
  }

  // Named internal call - linked directly to orders service
  const orders = serviceCall("orders", "GET /api/orders", {});
  if (!orders.ok) {
    return Response.json({ error: "orders service down" }, { status: 502 });
  }

  // External URL - not part of the system
  const external = fetch("https://api.stripe.com/v1/charges", {});
  if (!external.ok) {
    return Response.json({ error: "external service down" }, { status: 502 });
  }

  return Response.json({
    app: appName,
    users: health.json(),
    orders: orders.json(),
  });
}
