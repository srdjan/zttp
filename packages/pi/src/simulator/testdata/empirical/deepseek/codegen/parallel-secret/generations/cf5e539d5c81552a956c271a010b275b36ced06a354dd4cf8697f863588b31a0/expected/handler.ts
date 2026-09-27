import { env } from "zttp:env";
import { parallel } from "zttp:io";

structural Guard<T> = Proof<T, "state_isolated" | "no_secret_leakage">;

export function handler(req: Request): Guard<Response> {
  const readings = parallel([
    () => env("APP_NAME"),
    () => env("API_SECRET")
  ]);
  const apiSecret: string | undefined = readings[1];
  if (apiSecret === undefined) {
    return Response.json({ error: "api secret not configured" }, { status: 503 });
  }
  const appName: string | undefined = env("APP_NAME");
  return Response.json({ app: appName ?? "unknown" });
}
