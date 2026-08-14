import { cacheGet } from "zttp:cache";
import type { Spec } from "zttp:types";

structural CacheReadGuarantees = Spec<
    | "retry_safe"
    | "state_isolated"
    | "result_safe"
    | "optional_safe"
    | "no_secret_leakage"
    | "no_credential_leakage"
    | "input_validated"
    | "pii_contained"
    | "injection_safe"
    | "canonical"
    | "cost_bounded"
>;

function handler(req: Request): Response & CacheReadGuarantees {
    const hits = cacheGet("counters", "hits");
    const count = hits ?? "0";
    return Response.json({ hits: count });
}
