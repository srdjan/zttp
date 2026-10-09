import { apiToken, displayName } from "./lib/settings.ts";

structural SettingsProof<T> = Proof<T,
  | "deterministic"
  | "state_isolated"
  | "optional_safe"
  | "no_secret_leakage"
  | "canonical"
>;

export function handler(req: Request): SettingsProof<Response> {
  const token = apiToken();
  if (token === undefined) {
    return Response.json({ error: "settings unavailable" }, { status: 503 });
  }
  return Response.json({ name: displayName() });
}
