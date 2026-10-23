import { decodeUtf8 } from "zttp:bytes";
import { schemaCompile, validateJson } from "zttp:validate";

schemaCompile("item", JSON.stringify({
  type: "object",
  required: ["name"],
  properties: {
    name: { type: "string" }
  }
}));

function isString(value: unknown): value is string {
  return typeof value === "string";
}

export function handler(req: Request): Proof<Response,
  | "deterministic"
  | "state_isolated"
  | "fault_covered"
  | "result_safe"
  | "optional_safe"
  | "no_secret_leakage"
  | "no_credential_leakage"
  | "input_validated"
  | "canonical"
  | "cost_bounded"
> {
  const decoded = decodeUtf8(requestBody(req));
  if (!decoded.ok) {
    return Response.json({ errors: decoded.error }, { status: 400 });
  }
  const text = decoded.value;
  if (!isString(text)) {
    return Response.json({ errors: { message: "request body is not valid UTF-8" } }, { status: 400 });
  }
  const checked = validateJson("item", text);
  if (!checked.ok) {
    return Response.json({ errors: checked.error }, { status: 400 });
  }
  return Response.json(checked.value);
}
