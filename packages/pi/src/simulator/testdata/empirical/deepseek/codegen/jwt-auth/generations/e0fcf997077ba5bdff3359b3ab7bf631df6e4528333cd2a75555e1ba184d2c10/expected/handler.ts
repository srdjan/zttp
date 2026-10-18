import { env } from "zttp:env";
import { parseBearer, jwtVerify } from "zttp:auth";

structural Guard<T> = Proof<T,
  | "deterministic"
  | "state_isolated"
  | "result_safe"
  | "optional_safe"
  | "no_secret_leakage"
  | "no_credential_leakage"
>;

export function handler(req: Request): Guard<Response> {
  const secret = env("JWT_SECRET");
  if (secret === undefined) {
    return Response.json({ error: "unauthorized" }, { status: 401 });
  }

  const token = parseBearer(req.headers.get("authorization"));
  if (token === undefined) {
    return Response.json({ error: "unauthorized" }, { status: 401 });
  }

  const verified = jwtVerify(token, secret);
  if (!verified.ok) {
    return Response.json({ error: "unauthorized" }, { status: 401 });
  }

  return Response.json({ authenticated: true });
}
