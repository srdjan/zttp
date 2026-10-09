import { schemaCompile, validateJson } from "zttp:validate";

structural GuardResponse<T> = Proof<T, "state_isolated">;

schemaCompile("item", JSON.stringify({
  type: "object",
  required: ["name"],
  properties: {
    name: { type: "string" }
  }
}));

export function handler(req: Request): GuardResponse<Response> {
  const body = req.body ?? "";
  const checked = validateJson("item", body);
  if (!checked.ok) {
    return Response.json({ errors: checked.errors }, { status: 400 });
  }
  return Response.json(checked.value);
}
