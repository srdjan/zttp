// Proves: passing an optional env value into a response without a check is refused (ZTS308).
import { env } from "zttp:env";

structural Guardrails<T> = Proof<T, "optional_safe">;

function handler(req: Request): Guardrails<Response> {
    const secret = env("APP_NAME");
    return Response.json({ key: secret });
}
