import type { Spec } from "zttp:types";

structural HealthCheck = Spec<"deterministic">;

function handler(req: Request): Response & HealthCheck {
    return Response.json({ ok: true });
}
