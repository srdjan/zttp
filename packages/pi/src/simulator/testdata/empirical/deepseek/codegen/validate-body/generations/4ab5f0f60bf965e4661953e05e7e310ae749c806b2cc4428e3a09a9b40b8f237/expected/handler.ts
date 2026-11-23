import { schemaCompile, validateJson } from "zttp:validate";

schemaCompile("item", '{"type":"object","required":["name"],"properties":{"name":{"type":"string"}}}');

export function handler(req: Request): Proof<Response, "state_isolated" | "input_validated" | "canonical"> {
  const body = requestText(req);
  if (!body.ok) {
    return Response.json({ errors: body.error }, { status: 400 });
  }
  const text = body.value;
  if (typeof text !== "string") {
    return Response.json({ errors: "request body is not text" }, { status: 400 });
  }
  const decoded = validateJson("item", text);
  if (!decoded.ok) {
    return Response.json({ errors: decoded.error }, { status: 400 });
  }
  return Response.json(decoded.value);
}
