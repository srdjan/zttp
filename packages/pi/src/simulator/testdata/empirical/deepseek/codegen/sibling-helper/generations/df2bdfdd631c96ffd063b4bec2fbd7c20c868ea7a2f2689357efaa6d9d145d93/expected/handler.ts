import { apiToken, displayName } from "./lib/settings.ts";

structural Guard<T> = Proof<T,
  | "state_isolated"
  | "no_secret_leakage"
  | "canonical"
>;

export function handler(_req: Request): Guard<Response> {
  const token = apiToken();
  if (token === undefined) {
    return Response.json({ error: "unauthorized" }, { status: 503 });
  }
  return Response.json({ name: displayName() });
}
