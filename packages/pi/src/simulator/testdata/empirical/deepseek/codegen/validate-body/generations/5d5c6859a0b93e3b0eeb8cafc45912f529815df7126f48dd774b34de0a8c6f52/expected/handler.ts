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
  | "no_secret_leakage"
  | "no_credential_leakage"
  | "input_validated"
  | "pii_contained"
  | "injection_safe"
> {
  const body = requestText(req);
  if (!body.ok) {
    return Response.json({ errors: body.errors }, { status: 400 });
  }
  const checked = validateJson("item", String(body.value));
  if (!checked.ok) {
    return Response.json({ errors: checked.errors }, { status: 400 });
  }
  return Response.json(checked.value);
}
