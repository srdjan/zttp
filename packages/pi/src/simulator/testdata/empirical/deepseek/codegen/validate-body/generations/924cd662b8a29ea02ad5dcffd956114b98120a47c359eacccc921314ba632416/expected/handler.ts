import { schemaCompile, validateJson } from "zttp:validate";

structural ItemResponse<T> = Proof<T,
  | "state_isolated"
  | "fault_covered"
  | "result_safe"
  | "optional_safe"
  | "no_secret_leakage"
  | "no_credential_leakage"
  | "input_validated"
  | "canonical"
>;

schemaCompile("item", JSON.stringify({
  type: "object",
  required: ["name"],
  properties: {
    name: { type: "string" }
  }
}));

export function handler(req: Request): ItemResponse<Response> {
  const body = requestText(req);
  if (!body.ok) {
    return Response.json({ error: "request body could not be read" }, { status: 400 });
  }
  const raw = body.value;
  if (typeof raw !== "string") {
    return Response.json({ error: "request body must be text" }, { status: 400 });
  }
  const validated = validateJson("item", raw);
  if (!validated.ok) {
    return Response.json({ error: "request body does not match schema item", errors: validated.errors }, { status: 400 });
  }
  return Response.json(validated.value);
}
