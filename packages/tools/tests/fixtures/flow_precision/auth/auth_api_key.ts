import { env } from "zttp:env";
import { timingSafeEqual } from "zttp:auth";

export function handler(req: Request): Proof<Response, "no_secret_leakage" | "no_credential_leakage"> {
  const expected = env("API_KEY");
  if (expected === undefined) {
    return Response.json({ error: "server misconfigured" }, { status: 500 });
  }
  const presented = req.headers.get("x-api-key");
  if (presented === undefined) {
    return Response.json({ error: "unauthorized" }, { status: 401 });
  }
  if (!timingSafeEqual(presented, expected)) {
    return Response.json({ error: "unauthorized" }, { status: 401 });
  }
  return Response.json({ authenticated: true });
}
