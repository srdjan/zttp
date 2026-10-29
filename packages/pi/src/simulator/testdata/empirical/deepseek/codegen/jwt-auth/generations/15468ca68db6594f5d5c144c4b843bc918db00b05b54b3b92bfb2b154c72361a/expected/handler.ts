import { env } from "zttp:env";
import { parseBearer, jwtVerify } from "zttp:auth";

structural Guard<T> = Proof<T,
  | "state_isolated"
  | "fault_covered"
  | "no_secret_leakage"
  | "no_credential_leakage"
>;

export function handler(req: Request): Guard<Response> {
  const secret = env("JWT_SECRET");
  if (secret === undefined) {
    return Response.json({ error: "server misconfigured" }, { status: 500 });
  }
  const token = parseBearer(req.headers["authorization"] ?? "");
  if (token === undefined) {
    return Response.json({ error: "unauthorized" }, { status: 401 });
  }
  const verified = jwtVerify(token, secret);
  if (!verified.ok) {
    return Response.json({ error: "unauthorized" }, { status: 401 });
  }
  return Response.json({ authenticated: true });
}
