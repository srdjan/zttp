import { env } from "zttp:env";
import { parallel } from "zttp:io";

structural Guard<T> = Proof<T,
  | "deterministic"
  | "state_isolated"
  | "result_safe"
  | "optional_safe"
  | "no_secret_leakage"
  | "no_credential_leakage"
  | "input_validated"
  | "pii_contained"
  | "injection_safe"
  | "canonical"
  | "cost_bounded"
>;

export function handler(req: Request): Guard<Response> {
  const appNameResult = parallel({ appName: () => env("APP_NAME") });
  const apiSecretResult = parallel({ apiSecret: () => env("API_SECRET") });
  if (apiSecretResult.apiSecret === undefined) {
    return Response.json({ error: "server misconfigured" }, { status: 503 });
  }
  if (appNameResult.appName === undefined) {
    return Response.json({ error: "server misconfigured" }, { status: 503 });
  }
  return Response.json({ name: appNameResult.appName });
}
