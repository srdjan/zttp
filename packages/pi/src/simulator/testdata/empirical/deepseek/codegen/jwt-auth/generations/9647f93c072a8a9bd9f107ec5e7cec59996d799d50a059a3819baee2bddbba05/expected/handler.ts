import { parseBearer, jwtVerify } from "zttp:auth";
import { env } from "zttp:env";

structural AuthProof<T> = Proof<T,
  | "state_isolated"
  | "fault_covered"
  | "result_safe"
  | "optional_safe"
  | "no_secret_leakage"
  | "no_credential_leakage"
  | "canonical"
  | "cost_bounded"
>;

export function handler(req: Request): AuthProof<Response> {
  const secret = env("JWT_SECRET");
  if (secret === undefined) {
    return Response.json({ error: "unauthorized" }, { status: 401 });
  }
  const token = parseBearer(req.headers.get("Authorization") ?? "");
  if (token === undefined) {
    return Response.json({ error: "unauthorized" }, { status: 401 });
  }
  const verified = jwtVerify(token, secret);
  if (!verified.ok) {
    return Response.json({ error: "unauthorized" }, { status: 401 });
  }
  return Response.json({ authenticated: true });
}
