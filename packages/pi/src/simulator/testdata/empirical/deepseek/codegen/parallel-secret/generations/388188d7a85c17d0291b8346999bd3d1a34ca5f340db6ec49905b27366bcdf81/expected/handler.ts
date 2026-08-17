import { env } from "zttp:env";
import { parallel } from "zttp:io";

structural Guard<T> = Proof<T,
  | "state_isolated"
  | "no_secret_leakage"
  | "no_credential_leakage"
  | "canonical"
>;

export function handler(req: Request): Guard<Response> {
  const values = parallel({
    appName: () => env("APP_NAME"),
    apiSecret: () => env("API_SECRET"),
  });
  if (values.apiSecret === undefined) {
    return Response.json({ error: "missing required configuration" }, { status: 503 });
  }
  return Response.json({ appName: env("APP_NAME") });
}
