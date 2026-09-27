import { env } from "zttp:env";
import { parseBearer, jwtVerify } from "zttp:auth";

structural AuthGuard<T> = Proof<T,
  | "deterministic"
  | "state_isolated"
  | "fault_covered"
  | "result_safe"
  | "optional_safe"
  | "no_secret_leakage"
  | "no_credential_leakage"
  | "input_validated"
  | "pii_contained"
  | "injection_safe"
  | "canonical"
  | "cost_bounded"
>;

export function handler(req: Request): AuthGuard<Response> {
  const secret = env("JWT_SECRET");
  if (secret === undefined) {
    return Response.json({ error: "authentication unavailable" }, { status: 500 });
  }
  const authorization = req.headers.get("Authorization");
  if (authorization === undefined) {
    return Response.json({ error: "missing bearer token" }, { status: 401 });
  }
  const token = parseBearer(authorization);
  if (token === undefined) {
    return Response.json({ error: "missing bearer token" }, { status: 401 });
  }
  if (!jwtVerify(token, secret).ok) {
    return Response.json({ error: "invalid token" }, { status: 401 });
  }
  return Response.json({ authenticated: true });
}
