import { parseBearer, jwtVerify } from "zttp:auth";
import { env } from "zttp:env";

export function handler(req: Request): Proof<Response,
  | "state_isolated"
  | "result_safe"
  | "optional_safe"
  | "no_secret_leakage"
  | "no_credential_leakage"
  | "cost_bounded"
> {
  const secret: string | undefined = env("JWT_SECRET");
  if (secret === undefined) {
    return Response.json({ error: "unauthorized" }, { status: 401 });
  }
  const authorization: string | undefined = req.headers.get("Authorization");
  if (authorization === undefined) {
    return Response.json({ error: "unauthorized" }, { status: 401 });
  }
  const token: string | undefined = parseBearer(authorization);
  if (token === undefined) {
    return Response.json({ error: "unauthorized" }, { status: 401 });
  }
  const verified = jwtVerify(token, secret);
  if (!verified.ok) {
    return Response.json({ error: "unauthorized" }, { status: 401 });
  }
  return Response.json({ authenticated: true });
}
