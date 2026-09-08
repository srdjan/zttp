import { schemaCompile, validateJson } from "zttp:validate";

schemaCompile("item", JSON.stringify({
  type: "object",
  required: ["name"],
  properties: {
    name: { type: "string" }
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
  const raw = requestBody(req);
  if (!raw.ok) {
    return Response.json({ errors: raw.error }, { status: 400 });
  }
  const checked = validateJson("item", raw.value);
  if (!checked.ok) {
    return Response.json({ errors: checked.error }, { status: 400 });
  }
  return Response.json(checked.value);
}
