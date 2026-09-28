import { apiToken, displayName } from "./lib/settings.ts";

structural Guard<T> = Proof<T, "state_isolated" | "no_secret_leakage">;

export function handler(req: Request): Guard<Response> {
  const token = apiToken();
  if (token === undefined) {
    return Response.json({ error: "api token is not configured" }, { status: 503 });
  }
  return Response.json({ name: displayName() });
}
