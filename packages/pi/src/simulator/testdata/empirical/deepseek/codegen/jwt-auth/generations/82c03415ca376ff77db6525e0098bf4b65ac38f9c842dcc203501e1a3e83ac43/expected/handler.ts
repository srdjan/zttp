import { parseBearer, jwtVerify } from "zttp:auth";
import { env } from "zttp:env";

structural AuthGuard<T> = Proof<T, "no_secret_leakage" | "no_credential_leakage">;

export function handler(req: Request): AuthGuard<Response> {
  const header: string = req.headers["authorization"] ?? "";
  const token: string | undefined = parseBearer(header);
  if (token === undefined) {
    return Response.json({ error: "missing bearer token" }, { status: 401 });
  }
  const secret: string | undefined = env("JWT_SECRET");
  if (secret === undefined) {
    return Response.json({ error: "authentication unavailable" }, { status: 401 });
  }
  const verified = jwtVerify(token, secret);
  if (!verified.ok) {
    return Response.json({ error: "invalid token" }, { status: 401 });
  }
  return Response.json({ authenticated: true });
}
