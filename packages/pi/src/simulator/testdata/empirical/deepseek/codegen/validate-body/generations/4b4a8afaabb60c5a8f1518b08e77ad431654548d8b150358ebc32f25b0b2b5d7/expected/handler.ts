import { schemaCompile, validateJson } from "zttp:validate";

structural ItemProof<T> = Proof<T,
  | "deterministic"
  | "state_isolated"
  | "result_safe"
  | "optional_safe"
  | "input_validated"
  | "pii_contained"
  | "injection_safe"
  | "canonical"
  | "cost_bounded"
>;

schemaCompile("item", JSON.stringify({
  type: "object",
  required: ["name"],
  properties: {
    name: { type: "string" }
  }
}));

export function handler(req: Request): ItemProof<Response> {
  const checked = validateJson("item", req.body ?? "");
  if (!checked.ok) {
    return Response.json({ errors: checked.errors }, { status: 400 });
  }
  return Response.json(checked.value);
}
