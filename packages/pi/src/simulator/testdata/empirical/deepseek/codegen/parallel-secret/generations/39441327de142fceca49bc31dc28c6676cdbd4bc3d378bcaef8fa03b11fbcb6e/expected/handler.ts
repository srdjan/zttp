import { env } from "zttp:env";
import { parallel } from "zttp:io";

export function handler(req: Request): Proof<Response,
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
> {
  const appName = parallel([() => env("APP_NAME")])[0];
  const apiSecret = parallel([() => env("API_SECRET")])[0];
  if (apiSecret === undefined) {
    return Response.json({ error: "API_SECRET is not set" }, { status: 503 });
  }
  return Response.json({ app: appName });
}
