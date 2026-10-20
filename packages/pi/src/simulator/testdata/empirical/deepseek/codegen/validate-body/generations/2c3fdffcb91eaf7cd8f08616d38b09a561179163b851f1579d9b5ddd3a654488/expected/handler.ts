import { schemaCompile, validateJson } from "zttp:validate";

structural Guard<T> = Proof<T, "state_isolated">;

schemaCompile("item", JSON.stringify({
  type: "object",
  required: ["name"],
  properties: {
    name: { type: "string" }
  }
}));

export function handler(req: Request): Guard<Response> {
  const body = requestText(req);
  if (!body.ok) {
    return Response.json({ errors: body.error }, { status: 400 });
  }
  const text = body.value;
  if (typeof text !== "string") {
    return Response.json({ errors: "request body must be text" }, { status: 400 });
  }
  const validated = validateJson("item", text);
  if (!validated.ok) {
    return Response.json({ errors: validated.error }, { status: 400 });
  }
  return Response.json(validated.value);
}
