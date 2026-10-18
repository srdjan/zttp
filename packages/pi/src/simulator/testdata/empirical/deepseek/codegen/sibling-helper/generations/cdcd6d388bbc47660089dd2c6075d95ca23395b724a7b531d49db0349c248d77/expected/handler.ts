import { apiToken, displayName } from "./lib/settings.ts";

structural SafeResponse = Proof<Response, "no_secret_leakage">;

export function handler(request: Request): SafeResponse {
  const token = apiToken();

  if (token === undefined) {
    return Response.json({ error: "token unavailable" }, { status: 503 });
  }

  return Response.json({ name: displayName() });
}
