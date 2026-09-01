import { parallel } from "zttp:io";
import { env } from "zttp:env";

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
  const appName = parallel([() => env("APP_NAME")])[0];
  const apiSecret = parallel([() => env("API_SECRET")])[0];
  if (apiSecret === undefined) {
    return Response.json({ error: "API_SECRET is not set" }, { status: 503 });
  }
  if (appName === undefined) {
    return Response.json({ error: "APP_NAME is not set" }, { status: 500 });
  }
  return Response.json({ appName: appName });
}
