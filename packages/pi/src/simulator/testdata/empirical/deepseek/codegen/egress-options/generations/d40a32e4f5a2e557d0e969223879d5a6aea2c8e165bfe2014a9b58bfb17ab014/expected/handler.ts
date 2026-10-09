import { fetch } from "zttp:fetch";
import { schemaCompile, validateObject } from "zttp:validate";

schemaCompile("statusQuery", JSON.stringify({
  type: "object",
  required: ["probe"],
  properties: { probe: { type: "string", minLength: 1, maxLength: 64 } }
}));

export function handler(req: Request): Proof<Response,
  | "deterministic" | "state_isolated" | "fault_covered" | "result_safe"
  | "optional_safe" | "no_secret_leakage" | "no_credential_leakage"
  | "input_validated" | "pii_contained" | "injection_safe"
  | "canonical" | "cost_bounded"
> {
  const checked = validateObject("statusQuery", { probe: req.query["probe"] });
  if (!checked.ok) {
    return Response.json({ error: "missing or invalid probe query parameter" }, { status: 400 });
  }
  const upstream = fetch("https://api.example.com/v1/status", {
    method: "GET",
    headers: { accept: "application/json" },
    query: { probe: checked.value["probe"] },
    maxResponseBytes: 65536
  });
  if (!upstream.ok) {
    return Response.json({ error: "status service unavailable" }, { status: 502 });
  }
  return Response.json(upstream.json());
}
