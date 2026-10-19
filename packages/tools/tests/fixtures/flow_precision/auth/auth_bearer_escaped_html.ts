import { env } from "zttp:env";
import { parseBearer, jwtVerify } from "zttp:auth";
import { escapeHtml } from "zttp:text";

export function handler(req: Request): Proof<Response, "no_secret_leakage" | "no_credential_leakage" | "injection_safe"> {
  const secret = env("JWT_SECRET");
  if (secret === undefined) {
    return Response.json({ error: "server misconfigured" }, { status: 500 });
  }
  const header = req.headers.get("authorization");
  if (header === undefined) {
    return Response.json({ error: "unauthorized" }, { status: 401 });
  }
  const token = parseBearer(header);
  if (token === undefined) {
    return Response.json({ error: "unauthorized" }, { status: 401 });
  }
  const verified = jwtVerify(token, secret);
  if (!verified.ok) {
    return Response.json({ error: "unauthorized" }, { status: 401 });
  }
  return Response.html(["<p>", escapeHtml(req.url), "</p>"].join(""));
}
