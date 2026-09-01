import { apiToken, displayName } from "./lib/settings.ts";

export function handler(request: Request): Proof<Response, "no_secret_leakage"> {
  const token = apiToken();
  if (token === undefined) {
    return Response.json({ error: "unavailable" }, { status: 503 });
  }
  return Response.json({ name: displayName() });
}
