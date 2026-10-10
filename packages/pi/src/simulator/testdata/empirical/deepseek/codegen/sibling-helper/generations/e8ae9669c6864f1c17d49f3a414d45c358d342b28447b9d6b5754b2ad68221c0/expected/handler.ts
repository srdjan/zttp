import { apiToken, displayName } from "./lib/settings.ts";

structural TokenGuard<T> = Proof<T, "state_isolated" | "optional_safe" | "no_secret_leakage">;

export function handler(req: Request): TokenGuard<Response> {
  if (apiToken() === undefined) {
    return Response.json({ error: "service unavailable" }, { status: 503 });
  }
  return Response.json({ name: displayName() });
}
