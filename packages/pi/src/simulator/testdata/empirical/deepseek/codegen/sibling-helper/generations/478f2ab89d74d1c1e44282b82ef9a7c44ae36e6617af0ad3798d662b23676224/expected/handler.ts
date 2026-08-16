import { apiToken, displayName } from "./lib/settings.ts";

function handler(req: Request): Proof<Response, "read_only" | "retry_safe" | "state_isolated" | "stateless" | "result_safe" | "optional_safe" | "input_validated" | "pii_contained" | "injection_safe" | "canonical" | "cost_bounded"> {
    const token = apiToken();
    if (token === undefined) {
        return Response.json({ error: "unauthorized" }, { status: 503 });
    }
    return Response.json({ name: displayName() });
}
