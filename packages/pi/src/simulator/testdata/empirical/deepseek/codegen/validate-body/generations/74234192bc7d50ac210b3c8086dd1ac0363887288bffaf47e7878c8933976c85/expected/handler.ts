import { schemaCompile, validateJson } from "zttp:validate";

schemaCompile("item", JSON.stringify({
  type: "object",
  required: ["name"],
  properties: {
    name: { type: "string" }
  }
}));

structural ItemProof<T> = Proof<T, "deterministic" | "state_isolated" | "input_validated" | "result_safe" | "optional_safe" | "no_secret_leakage" | "no_credential_leakage" | "pii_contained" | "injection_safe" | "canonical" | "cost_bounded" | "fault_covered">;

export function handler(req: Request): ItemProof<Response> {
  const checked = validateJson("item", requestJson);
  if (!checked.ok) {
    return Response.json({ errors: checked.errors }, { status: 400 });
  }
  return Response.json(checked.value);
}
