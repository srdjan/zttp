// Should warn: declared variable is never used
import type { Spec } from "zttp:types";

structural Guardrails = Spec<"result_safe">;

function handler(req: Request): Response & Guardrails {
    const unused = "hello";
    return Response.json({ ok: true });
}
