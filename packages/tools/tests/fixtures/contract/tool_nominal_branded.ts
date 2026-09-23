import { toolCatalog } from "zttp:tool";
import { routerMatch } from "zttp:router";
import { schemaCompile, validateJson } from "zttp:validate";

nominal OrderId = string;

schemaCompile("LookupInput", "{\"type\":\"object\",\"additionalProperties\":false,\"required\":[\"id\"],\"properties\":{\"id\":{\"type\":\"string\",\"maxLength\":16}}}");
schemaCompile("LookupOutput", "{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{\"id\":{\"type\":\"string\",\"maxLength\":16}}}");

toolCatalog({
  lookup: {
    route: "POST /tools/lookup",
    description: "Look up one order by its id.",
    input: "LookupInput",
    output: "LookupOutput",
    maxInputBytes: 256
  }
});

function describe(id: OrderId): string {
  return id;
}

function lookup(req: Request): Response {
  const text = requestText(req);
  if (!text.ok) {
    return Response.json({ error: "no body" }, { status: 400 });
  }
  const parsed = validateJson("LookupInput", String(text.value));
  if (!parsed.ok) {
    return Response.json({ error: "invalid" }, { status: 400 });
  }
  const input = parsed.value;
  const id: OrderId = input.id;
  return Response.json({ id: describe(id) });
}

const routes = { "POST /tools/lookup": lookup };

function handler(req: Request): Proof<Response, "deterministic" | "read_only"> {
  const found = routerMatch(routes, req);
  if (found !== undefined) {
    return found.handler(req);
  }
  return Response.json({ error: "not found" }, { status: 404 });
}
