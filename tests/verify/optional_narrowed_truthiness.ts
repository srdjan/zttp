// Should pass: explicit presence narrows optional
import { env } from "zttp:env";
import type { Spec } from "zttp:types";

structural Guardrails = Spec<"optional_safe">;

function handler(req: Request): Response & Guardrails {
    const secret = env("SECRET");
    if (secret !== undefined) {
        return Response.json({ hasSecret: true });
    }
    return Response.json({ error: "no secret" }, { status: 500 });
}
