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

structural ItemProof<T> = Proof<T,
  | "state_isolated"
  | "input_validated"
>;

export function handler(req: Request): ItemProof<Response> {
  const body = requestText(req);
  if (!body.ok) {
    return Response.json({ errors: body.errors }, { status: 400 });
  }
  const raw = body.value;
  if (!isString(raw)) {
    return Response.json({ errors: body.errors }, { status: 400 });
  }
  const checked = validateJson("item", raw);
  if (!checked.ok) {
    return Response.json({ errors: checked.errors }, { status: 400 });
  }
  return Response.json(checked.value);
}
