import { env } from "zttp:env";
import { jwtVerify, parseBearer } from "zttp:auth";

structural Guard<T> = Proof<T, "state_isolated" | "fault_covered" | "no_secret_leakage" | "no_credential_leakage">;

export function handler(req: Request): Guard<Response> {
  const authorizationHeader = req.headers["authorization"];
  if (typeof authorizationHeader !== "string") {
    return Response.json({ error: "missing or malformed authorization header" }, { status: 401 });
  }
  const token = parseBearer(authorizationHeader);
  if (token === undefined) {
    return Response.json({ error: "missing bearer token" }, { status: 401 });
  }
  const secret = env("JWT_SECRET");
  if (secret === undefined) {
    return Response.json({ error: "authentication unavailable" }, { status: 500 });
  }
  const verified = jwtVerify(token, secret, "HS256");
  if (!verified.ok) {
    return Response.json({ error: "invalid token" }, { status: 401 });
  }
  return Response.json({ authenticated: true });
}
