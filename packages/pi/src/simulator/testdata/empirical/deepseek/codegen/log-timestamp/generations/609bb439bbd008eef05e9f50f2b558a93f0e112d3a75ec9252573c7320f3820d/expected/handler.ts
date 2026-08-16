import { logInfo } from "zttp:log";

export function handler(req: Request): Proof<Response, "deterministic" | "state_isolated"> {
    const at = Date.now();
    logInfo("served request", { at: at });
    return Response.json({ ok: true });
}
