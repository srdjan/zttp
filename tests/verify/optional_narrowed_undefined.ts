// Should pass: if (val !== undefined) narrows optional
import { env } from "zttp:env";

structural Guardrails<T> = Proof<T, "optional_safe">;

function handler(req: Request): Guardrails<Response> {
    const secret = env("SECRET");
    if (secret !== undefined) {
        return Response.json({ hasSecret: true });
    }
    return Response.json({ error: "no secret" }, { status: 500 });
}
