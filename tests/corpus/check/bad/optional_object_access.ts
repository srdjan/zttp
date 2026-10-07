// Proves: reading a property of a route lookup that may be undefined, without a check, is refused (ZTS309).
import { routerMatch } from "zttp:router";

function getHome(req: Request): Response {
    return Response.json({ status: "ok" });
}

const routes = {
    "GET /": getHome,
};

structural Guardrails<T> = Proof<T, "optional_safe">;

function handler(req: Request): Guardrails<Response> {
    const route = routerMatch(routes, req);
    return route.handler(req);
}
