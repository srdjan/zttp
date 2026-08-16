import { cacheGet } from "zttp:cache";

export function handler(req: Request): Proof<Response,
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
> {
    const hits = cacheGet("counters", "hits") ?? "0";
    return Response.json({ hits: hits });
}
