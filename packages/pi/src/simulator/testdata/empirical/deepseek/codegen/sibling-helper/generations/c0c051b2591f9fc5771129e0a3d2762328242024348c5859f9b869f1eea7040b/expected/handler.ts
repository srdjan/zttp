import { apiToken, displayName } from "./lib/settings.ts";

structural Guard<T> = Proof<T,
  | "deterministic"
  | "state_isolated"
  | "optional_safe"
  | "no_secret_leakage"
>;

export function handler(req: Request): Guard<Response> {
  if (apiToken() === undefined) {
    return Response.json({ error: "app token is not configured" }, { status: 503 });
  }
  return Response.json({ name: displayName() });
}
