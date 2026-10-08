// Proves: a toolCatalog entry without maxInputBytes is refused, so the handler publishes no tool (ZTS513).
import { toolCatalog } from "zttp:tool";
import { routerMatch } from "zttp:router";
import { schemaCompile } from "zttp:validate";

schemaCompile("PingInput", "{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{}}");
schemaCompile("PingOutput", "{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{\"ok\":{\"type\":\"boolean\"}}}");

toolCatalog({
    ping: {
        route: "POST /tools/ping",
        description: "Answer that the service is up.",
        input: "PingInput",
        output: "PingOutput"
    }
});

function ping(req: Request): Response {
    return Response.json({ ok: true });
}

const routes = { "POST /tools/ping": ping };

function handler(req: Request): Proof<Response, "deterministic" | "read_only"> {
    const found = routerMatch(routes, req);
    if (found !== undefined) {
        return found.handler(req);
    }
    return Response.json({ error: "not found" }, { status: 404 });
}
