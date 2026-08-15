// Should pass: env() ?? "default" resolves optionality
import { env } from "zttp:env";

structural Guardrails<T> = Proof<T, "optional_safe">;

function handler(req: Request): Guardrails<Response> {
    const name = env("APP_NAME") ?? "zttp";
    return Response.json({ app: name });
}
