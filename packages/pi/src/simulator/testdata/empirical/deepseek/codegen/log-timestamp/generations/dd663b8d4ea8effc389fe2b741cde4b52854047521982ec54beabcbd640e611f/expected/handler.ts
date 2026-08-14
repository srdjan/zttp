import { logInfo } from "zttp:log";
import type { Spec } from "zttp:types";

structural HandlerGuarantees = Spec<
    | "state_isolated"
    | "result_safe"
    | "optional_safe"
    | "no_secret_leakage"
    | "no_credential_leakage"
    | "input_validated"
    | "pii_contained"
    | "injection_safe"
    | "canonical"
>;

function handler(req: Request): Response & HandlerGuarantees {
    const servedAt = Date.now();
    logInfo("served request", { method: req.method, path: req.path, servedAt: servedAt });
    return Response.json({ ok: true });
}
