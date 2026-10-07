// Proves: returning early on an undefined optional narrows it for the rest of the handler.
import { env } from "zttp:env";

structural Guardrails<T> = Proof<T, "optional_safe">;

function handler(req: Request): Guardrails<Response> {
    const secret = env("SECRET");
    if (secret === undefined) {
        return Response.json({ error: "no secret" }, { status: 500 });
    }
    return Response.json({ hasSecret: true });
}
