import { logInfo } from "zttp:log";
import type { Spec } from "zttp:types";

function handler(req: Request): Response & Spec<"deterministic" | "state_isolated" | "result_safe" | "optional_safe" | "no_secret_leakage" | "no_credential_leakage" | "input_validated" | "pii_contained" | "injection_safe" | "canonical" | "cost_bounded"> {
    logInfo("request served", { timestamp: Date.now() });
    return Response.json({ ok: true });
}
