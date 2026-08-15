// Should fail: optional value used without checking for undefined
import { env } from "zttp:env";

structural Guardrails<T> = Proof<T, "optional_safe">;

function handler(req: Request): Guardrails<Response> {
    const secret = env("SECRET");
    return Response.json({ key: secret });
}
