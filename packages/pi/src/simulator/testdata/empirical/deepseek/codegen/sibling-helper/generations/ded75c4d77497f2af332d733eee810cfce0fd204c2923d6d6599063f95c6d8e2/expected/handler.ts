import { apiToken, displayName } from "./lib/settings.ts";

structural HandlerResponse = Proof<Response, "no_secret_leakage">;

export function handler(req: Request): HandlerResponse {
  const token: string | undefined = apiToken();
  if (token === undefined) {
    return Response.json({}, { status: 503 });
  }
  return Response.json({ name: displayName() });
}
