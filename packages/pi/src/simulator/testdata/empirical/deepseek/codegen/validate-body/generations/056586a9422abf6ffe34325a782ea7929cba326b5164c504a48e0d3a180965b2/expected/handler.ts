import { schemaCompile, validateJson } from "zttp:validate";

structural ItemProof<T> = Proof<T,
  | "deterministic"
  | "state_isolated"
  | "input_validated"
  | "injection_safe"
  | "no_secret_leakage"
  | "no_credential_leakage"
  | "pii_contained"
>;

schemaCompile("item", JSON.stringify({
  type: "object",
  required: ["name"],
  properties: {
    name: { type: "string" }
  }
}));

export function handler(req: Request): ItemProof<Response> {
  const raw = req.body;
  if (raw === undefined) {
    return Response.json({ errors: "missing request body" }, { status: 400 });
  }
  const parsed = validateJson("item", raw);
  if (!parsed.ok) {
    return Response.json({ errors: parsed.error }, { status: 400 });
  }
  return Response.json(parsed.value);
}
