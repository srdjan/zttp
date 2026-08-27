import { env } from "zttp:env";
import { parallel } from "zttp:io";

export function handler(req: Request): Proof<Response,
  | "result_safe"
  | "optional_safe"
  | "no_secret_leakage"
  | "no_credential_leakage"
  | "canonical"
  | "cost_bounded"
> {
  const appNameValues = parallel([() => env("APP_NAME")]);
  const appName = appNameValues[0];
  const apiSecretValues = parallel([() => env("API_SECRET")]);
  const apiSecret = apiSecretValues[0];
  if (apiSecret === undefined) {
    return Response.json({ error: "missing required configuration" }, { status: 503 });
  }
  return Response.json({ appName: appName });
}
