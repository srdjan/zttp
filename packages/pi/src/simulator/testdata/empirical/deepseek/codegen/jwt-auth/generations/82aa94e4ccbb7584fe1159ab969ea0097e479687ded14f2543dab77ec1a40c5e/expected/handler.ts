import { env } from "zttp:env";
import { parseBearer, jwtVerify } from "zttp:auth";

export function handler(req: Request): Proof<Response,
  | "deterministic"
  | "state_isolated"
  | "fault_covered"
  | "optional_safe"
  | "result_safe"
  | "no_secret_leakage"
  | "no_credential_leakage"
  | "canonical"
> {
  const secret = env("JWT_SECRET");
  if (secret === undefined) {
    return Response.json({ error: "unauthorized" }, { status: 401 });
  }
  const authHeader = req.headers.get("Authorization");
  if (authHeader === undefined) {
    return Response.json({ error: "unauthorized" }, { status: 401 });
  }
  const token = parseBearer(authHeader);
  if (token === undefined) {
    return Response.json({ error: "unauthorized" }, { status: 401 });
  }
  const verified = jwtVerify(token, secret);
  if (!verified.ok) {
    return Response.json({ error: "unauthorized" }, { status: 401 });
  }
  return Response.json({ authenticated: true });
}
