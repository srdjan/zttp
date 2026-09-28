import { schemaCompile, validateJson } from "zttp:validate";

schemaCompile("item", JSON.stringify({
  type: "object",
  required: ["name"],
  properties: {
    name: { type: "string" }
  }
}));

structural ItemProof<T> = Proof<T,
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
>;

export function handler(req: Request): ItemProof<Response> {
  const body = req.body;
  if (body === undefined) {
    return Response.json({ errors: ["request body is required"] }, { status: 400 });
  }
  const checked = validateJson("item", body);
  if (!checked.ok) {
    return Response.json({ errors: checked.errors }, { status: 400 });
  }
  return Response.json(checked.value);
}
