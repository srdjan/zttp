import { fetch } from "zttp:fetch";

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
  const upstream = fetch("https://api.example.com/v1/status", {
    method: "GET",
    headers: { "accept": "application/json" },
    maxResponseBytes: 65536
  });
  if (!upstream.ok) {
    return Response.json({ error: "upstream unavailable" }, { status: 502 });
  }
  return Response.json(upstream.json());
}
