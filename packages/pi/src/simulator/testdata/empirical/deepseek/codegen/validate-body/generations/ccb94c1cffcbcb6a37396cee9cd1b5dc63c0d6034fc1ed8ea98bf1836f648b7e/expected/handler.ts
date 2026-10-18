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
  const checked = validateJson("item", req.body ?? "");
  if (!checked.ok) {
    return Response.json({ errors: checked.error }, { status: 400 });
  }
  return Response.json(checked.value);
}
