import { fetch } from "zttp:fetch";
import { schemaCompile, validateObject } from "zttp:validate";

schemaCompile("cityQuery", JSON.stringify({
  type: "object",
  required: ["city"],
  properties: {
    city: { type: "string", minLength: 1, maxLength: 64 }
  }
}));

export function handler(req: Request): Proof<Response,
  | "deterministic"
  | "state_isolated"
  | "fault_covered"
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
  const checked = validateObject("cityQuery", { city: req.query["city"] });
  if (!checked.ok) {
    return Response.json({ error: "missing or invalid city query parameter" }, { status: 400 });
  }
  const upstream = fetch("https://api.open-meteo.com/v1/forecast", {
    query: { city: checked.value["city"] },
    maxResponseBytes: 65536
  });
  if (!upstream.ok) {
    return Response.json({ error: "weather service unavailable" }, { status: 502 });
  }
  return Response.json(upstream.json());
}
