import { parseBearer, jwtVerify } from "zttp:auth";
import { env } from "zttp:env";

structural AuthProof<T> = Proof<T,
  | "fault_covered"
  | "result_safe"
  | "optional_safe"
  | "no_secret_leakage"
  | "no_credential_leakage"
  | "canonical"
>;

export function handler(req: Request): AuthProof<Response> {
  const secret = env("JWT_SECRET");
  if (secret === undefined) {
    return Response.json({ error: "authentication unavailable" }, { status: 500 });
  }
  const token = parseBearer(req.headers.get("Authorization") ?? "");
  if (token === undefined) {
    return Response.json({ error: "missing bearer token" }, { status: 401 });
  }
  const verified = jwtVerify(token, secret);
  if (!verified.ok) {
    return Response.json({ error: "invalid token" }, { status: 401 });
  }
  return Response.json({ authenticated: true });
}
