import { apiToken, displayName } from "./lib/settings.ts";

structural HandlerProof<T> = Proof<T,
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

export function handler(req: Request): HandlerProof<Response> {
  const token = apiToken();
  if (token === undefined) {
    return Response.json({ error: "missing api token" }, { status: 503 });
  }
  return Response.json({ name: displayName() });
}
