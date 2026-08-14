import { apiToken, displayName } from "./lib/settings";
import type { Spec } from "zttp:types";

function handler(req: Request): Response & Spec<
    | "read_only"
    | "retry_safe"
    | "state_isolated"
    | "injection_safe"
> {
    const token = apiToken();
    if (token === undefined) {
        return Response.json({ error: "service unavailable" }, { status: 503 });
    }
    return Response.json({ name: displayName() });
}
