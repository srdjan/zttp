import { env } from "zttp:env";
import { parallel } from "zttp:io";

structural Guard<T> = Proof<T,
  | "state_isolated"
  | "no_secret_leakage"
  | "no_credential_leakage"
  | "result_safe"
  | "optional_safe"
  | "canonical"
  | "cost_bounded"
>;

export function handler(req: Request): Guard<Response> {
  const secretBox = parallel({ apiSecret: () => env("API_SECRET") });
  const apiSecret = secretBox.apiSecret;
  if (apiSecret === undefined) {
    return Response.json({ error: "API_SECRET is not configured" }, { status: 503 });
  }
  const nameBox = parallel({ appName: () => env("APP_NAME") });
  const name = nameBox.appName ?? "";
  return Response.json({ appName: name });
}
