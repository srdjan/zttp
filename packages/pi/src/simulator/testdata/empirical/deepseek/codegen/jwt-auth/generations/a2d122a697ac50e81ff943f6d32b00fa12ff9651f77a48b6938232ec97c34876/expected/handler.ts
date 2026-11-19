import { env } from "zttp:env";
import { jwtVerify, parseBearer } from "zttp:auth";

export function handler(req: Request): Proof<Response,
  | "fault_covered"
  | "result_safe"
  | "optional_safe"
  | "no_secret_leakage"
  | "no_credential_leakage"
  | "canonical"
  | "cost_bounded"
> {
  const secret = env("JWT_SECRET");
  if (secret === undefined) {
    return Response.json({ error: "authentication unavailable" }, { status: 500 });
  }
  const authorization = req.headers.authorization;
  const token = parseBearer(authorization ?? "");
  if (token === undefined) {
    return Response.json({ error: "missing bearer token" }, { status: 401 });
  }
  const verified = jwtVerify(token, secret);
  if (!verified.ok) {
    return Response.json({ error: "invalid token" }, { status: 401 });
  }
  return Response.json({ authenticated: true });
}
