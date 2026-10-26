import { routerMatch } from "zttp:router";
import { schemaCompile } from "zttp:validate";
import { decodeJson, decodeQuery } from "zttp:decode";

schemaCompile(
  "profile.update",
  JSON.stringify({
    type: "object",
    properties: { displayName: { type: "string" } },
    required: ["displayName"],
  }),
);

schemaCompile(
  "profile.query",
  JSON.stringify({
    type: "object",
    properties: { verbose: { type: "boolean" } },
  }),
);

function updateProfile(req: Request): Response {
  const parsed = decodeJson("profile.update", req.body ?? "{}");
  let displayName = "anonymous";
  if (parsed.ok) {
    displayName = parsed.value.displayName;
  }
  const query = decodeQuery("profile.query", req.query ?? {});
  let verbose = false;
  if (query.ok) {
    verbose = query.value.verbose ?? false;
  }
  const clientId = req.headers.get("x-client-id") ?? "anonymous";

  return Response.json({
    id: req.params.id,
    clientId: clientId,
    verbose: verbose,
    displayName: displayName,
  });
}

const routes = { "POST /profiles/:id": updateProfile };

function handler(req: Request): Proof<Response, "state_isolated" | "no_secret_leakage" | "injection_safe"> {
  const found = routerMatch(routes, req);
  if (found !== undefined) {
    req.params = found.params;
    return found.handler(req);
  }

  return Response.json({ error: "Not Found" }, { status: 404 });
}
