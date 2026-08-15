import type { Spec } from "zttp:types";

structural HealthGuarantees = Spec<
    | "deterministic"
    | "read_only"
    | "retry_safe"
    | "idempotent"
    | "state_isolated"
    | "pure"
    | "injection_safe"
>;

function handler(req: Request): Response & HealthGuarantees {
    return match (req) {
        when { method: "GET", path: "/health" }:
            Response.json({ ok: true })
        default:
            Response.text("Not Found", { status: 404 })
    };
}
