import { schemaCompile, validateJson } from "zttp:validate";

schemaCompile(
  "item",
  "{\"type\":\"object\",\"required\":[\"name\"],\"properties\":{\"name\":{\"type\":\"string\"}}}",
);

structural Guard<T> = Proof<T, "deterministic" | "state_isolated" | "result_safe" | "canonical">;

export function handler(req: Request): Guard<Response> {
  const body = requestText(req);
  if (!body.ok) {
    return Response.json({ errors: body.error }, { status: 400 });
  }
  const text = body.value;
  if (typeof text !== "string") {
    return Response.json({ errors: "request body is not JSON text" }, { status: 400 });
  }
  const checked = validateJson("item", text);
  if (!checked.ok) {
    return Response.json({ errors: checked.error }, { status: 400 });
  }
  return Response.json(checked.value);
}
