import { parseBearer, jwtVerify } from "zttp:auth";
import { env } from "zttp:env";

structural AuthProof<T> = Proof<T,
  | "state_isolated"
  | "fault_covered"
  | "result_safe"
  | "optional_safe"
  | "no_secret_leakage"
  | "no_credential_leakage"
  | "input_validated"
  | "injection_safe"
  | "canonical"
  | "cost_bounded"
>;

export function handler(req: Request): AuthProof<Response> {
  const secret = env("JWT_SECRET");
  if (secret === undefined) {
    return Response.json({ error: "auth not configured" }, { status: 500 });
  }
  const header = req.headers.get("Authorization") ?? "";
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
