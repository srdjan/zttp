import { env } from "zttp:env";
import { parallel } from "zttp:io";

structural Guard<T> = Proof<T, "state_isolated">;

export function handler(req: Request): Guard<Response> {
  const results = parallel([() => env("APP_NAME"), () => env("API_SECRET")]);
  const apiSecret = results[1];
  if (apiSecret === undefined) {
    return Response.json({ error: "service unavailable" }, { status: 503 });
  }
  const appName: string = env("APP_NAME") ?? "unknown";
  return Response.json({ app_name: appName });
}
