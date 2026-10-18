import { apiToken, displayName } from "./lib/settings.ts";

structural SettingsResponse = Proof<Response,
  | "deterministic"
  | "state_isolated"
  | "optional_safe"
  | "no_secret_leakage"
>;

export function handler(req: Request): SettingsResponse {
  const token = apiToken();
  if (token === undefined) {
    return Response.json({ error: "service unavailable" }, { status: 503 });
  }
  return Response.json({ name: displayName() });
}
