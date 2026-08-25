import { env } from "zttp:env";
import { parallel } from "zttp:io";

structural Guard<T> = Proof<T,
  | "state_isolated"
  | "optional_safe"
  | "no_secret_leakage"
  | "no_credential_leakage"
  | "canonical"
  | "cost_bounded"
>;

export function handler(req: Request): Guard<Response> {
  const appValues = parallel({
    appName: (): string | undefined => env("APP_NAME")
  });
  const secretValues = parallel({
    apiSecret: (): string | undefined => env("API_SECRET")
  });
  if (secretValues.apiSecret === undefined) {
    return Response.json({ error: "API_SECRET is not set" }, { status: 503 });
  }
  return Response.json({ appName: appValues.appName });
}
