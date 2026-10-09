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
  | "input_validated"
  | "pii_contained"
  | "injection_safe"
  | "canonical"
  | "cost_bounded"
>;

export function handler(req: Request): Guard<Response> {
  const secret = env("JWT_SECRET");
  if (secret === undefined) {
    return Response.json({ error: "unauthorized" }, { status: 401 });
  }
  const header = req.headers.get("Authorization");
  if (header === undefined) {
    return Response.json({ error: "unauthorized" }, { status: 401 });
  }
  const token = parseBearer(header);
  if (token === undefined) {
    return Response.json({ error: "unauthorized" }, { status: 401 });
  }
  const verified = jwtVerify(token, secret);
  if (!verified.ok) {
    return Response.json({ error: "unauthorized" }, { status: 401 });
  }
  return Response.json({ authenticated: true });
}
