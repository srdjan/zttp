import { parseBearer, jwtVerify } from "zttp:auth";
import { env } from "zttp:env";

structural Guard<T> = Proof<T,
  | "deterministic"
  | "state_isolated"
  | "fault_covered"
  | "result_safe"
  | "optional_safe"
  | "no_secret_leakage"
  | "no_credential_leakage"
  | "canonical"
>;

export function handler(req: Request): Guard<Response> {
  const token = parseBearer(req.headers["authorization"] ?? "");
  if (token === undefined) {
    return Response.json({ error: "unauthorized" }, { status: 401 });
  }
  const secret = env("JWT_SECRET");
  if (secret === undefined) {
    return Response.json({ error: "unauthorized" }, { status: 401 });
  }
  const verified = jwtVerify(token, secret);
  if (!verified.ok) {
    return Response.json({ error: "unauthorized" }, { status: 401 });
  }
  return Response.json({ authenticated: true });
}
