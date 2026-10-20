import { parseBearer, jwtVerify } from "zttp:auth";
import { env } from "zttp:env";

export function handler(req: Request): Proof<Response,
  | "deterministic"
  | "state_isolated"
  | "no_secret_leakage"
  | "no_credential_leakage"
> {
  const secret = env("JWT_SECRET");
  if (secret === undefined) {
    return Response.json({ error: "auth unavailable" }, { status: 500 });
  }
  const token = parseBearer(req.headers.get("authorization") ?? "");
  if (token === undefined) {
    return Response.json({ error: "unauthorized" }, { status: 401 });
  }
  const verified = jwtVerify(token, secret);
  if (!verified.ok) {
    return Response.json({ error: "unauthorized" }, { status: 401 });
  }
  return Response.json({ authenticated: true });
}
