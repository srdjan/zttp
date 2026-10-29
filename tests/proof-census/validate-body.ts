// Proves: the proof-ratchet census keeps a certified handler that reads a
// Result. This is the validate-body handler from the 2026-10-27 DeepSeek
// recording; the census floor no longer depends on what a later recording draws.
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
  const parsed = requestJson(req);
  if (!parsed.ok) {
    return Response.json({ error: "invalid JSON request body" }, { status: 400 });
  }
  const checked = validateJson("item", JSON.stringify(parsed.value));
  if (!checked.ok) {
    return Response.json({ errors: checked.errors }, { status: 400 });
  }
  return Response.json(checked.value);
}
