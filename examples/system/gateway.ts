// Gateway handler - authenticates and routes to internal services
import { parseBearer, jwtVerify } from "zttp:auth";
import { env } from "zttp:env";
import { serviceCall } from "zttp:service";

structural Guardrails<T> = Proof<T,
    | "injection_safe"
    | "state_isolated"
    | "no_secret_leakage"
>;

function handler(req: Request): Guardrails<Response> {
  // Authenticate
  const token = parseBearer(req.headers["authorization"]);
  if (token === undefined) {
    return Response.json({ error: "missing token" }, { status: 401 });
  }

  const secret = env("JWT_SECRET");
  if (secret === undefined) {
    return Response.json({ error: "server misconfigured" }, { status: 500 });
  }

  const auth = jwtVerify(token, secret);
  if (!auth.ok) {
    return Response.json({ error: "unauthorized" }, { status: 401 });
  }

  // Route to users service
  const user = serviceCall("users", "GET /api/users/:id", {
    params: { id: "self" },
  });
  if (user.status === 200) {
    return Response.json({ user: user.json() });
  }
  return Response.json(
    { error: "user service unavailable" },
    { status: 502 },
  );
}
