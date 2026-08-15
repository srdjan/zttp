import { env } from "zttp:env";
import { parallel } from "zttp:io";
import type { Spec } from "zttp:types";

structural EnvGuarantees = Spec<
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

function handler(req: Request): Response & EnvGuarantees {
  const [appName, secretStatus] = parallel([
    () => env("APP_NAME"),
    () => {
      const secret = env("API_SECRET");
      if (secret === undefined) {
        return 503;
      }
      return 200;
    },
  ]);
  if (secretStatus === 503) {
    return Response.json({ error: "API_SECRET is not set" }, { status: 503 });
  }
  return Response.json({ app: appName });
}
