import { env } from "zttp:env";
import { parseBearer, jwtVerify } from "zttp:auth";

structural AuthGuard<T> = Proof<T,
  | "state_isolated"
  | "result_safe"
  | "optional_safe"
  | "no_secret_leakage"
  | "no_credential_leakage"
  | "canonical"
>;

export function handler(req: Request): AuthGuard<Response> {
  const header = req.headers.get("Authorization");
  if (header === undefined) {
    return Response.json({ error: "missing bearer token" }, { status: 401 });
  }
  const token = parseBearer(header);
  if (token === undefined) {
    return Response.json({ error: "invalid bearer token" }, { status: 401 });
  }
  const secret = env("JWT_SECRET");
  if (secret === undefined) {
    return Response.json({ error: "server not configured" }, { status: 500 });
  }
  const verified = jwtVerify(token, secret);
  if (!verified.ok) {
    return Response.json({ error: "invalid token" }, { status: 401 });
  }
  return Response.json({ authenticated: true });
}
