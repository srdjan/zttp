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
  const decoded = validateJson("item", req.body ?? "");
  if (!decoded.ok) {
    return Response.json({ errors: decoded.error }, { status: 400 });
  }
  return Response.json(decoded.value);
}
