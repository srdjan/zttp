import type { Spec } from "zttp:types";

structural HealthGuarantees = Spec<
    | "deterministic"
    | "idempotent"
    | "no_secret_leakage"
    | "injection_safe"
>;

function handler(req: Request): Response & HealthGuarantees {
    if (req.method === "GET" && req.path === "/health") {
        return Response.json({ ok: true });
    }
    return Response.text("Not Found", { status: 404 });
}
