import { env } from "zttp:env";
import { parallel } from "zttp:io";

structural EnvProof<T> = Proof<T,
  | "state_isolated"
  | "result_safe"
  | "optional_safe"
  | "no_secret_leakage"
  | "no_credential_leakage"
  | "canonical"
  | "cost_bounded"
>;

export function handler(req: Request): EnvProof<Response> {
  const read = parallel({
    appName: () => env("APP_NAME"),
    apiSecret: () => env("API_SECRET"),
  });
  const apiSecret: string | undefined = read["apiSecret"];
  if (apiSecret === undefined) {
    return Response.json({ error: "service unavailable" }, { status: 503 });
  }
  const appName: string = env("APP_NAME") ?? "";
  return Response.json({ appName: appName });
}
