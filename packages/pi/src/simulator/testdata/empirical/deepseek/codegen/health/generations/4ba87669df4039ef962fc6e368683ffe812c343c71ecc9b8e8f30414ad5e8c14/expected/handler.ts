import { routerMatch } from "zttp:router";

structural HealthGuarantees<T> = Proof<T,
    | "deterministic"
    | "read_only"
    | "retry_safe"
    | "idempotent"
    | "state_isolated"
    | "fault_covered"
    | "injection_safe"
>;

function getHealth(req: Request): Response {
    return Response.json({ ok: true });
}

const routes = {
    "GET /health": getHealth,
};

function handler(req: Request): HealthGuarantees<Response> {
    const found = routerMatch(routes, req);
    if (found !== undefined) {
        req.params = found.params;
        return found.handler(req);
    }
    return Response.json({ error: "Not Found" }, { status: 404 });
}
