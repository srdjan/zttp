import { fetch } from "zttp:fetch";

function handler(req: Request): Proof<Response, "state_isolated" | "result_safe" | "optional_safe" | "no_secret_leakage" | "no_credential_leakage" | "input_validated" | "pii_contained" | "injection_safe" | "canonical" | "cost_bounded"> {
  const res = fetch("https://api.example.com/v1/status", { method: "GET", headers: { accept: "application/json" } });
  if (!res.ok) {
    return Response.json({ error: "upstream" }, { status: 502 });
  }
  return Response.json(res.body);
}
