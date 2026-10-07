// Proves: a handler that validates input, checks the Result, and returns on both branches passes every stage.
import { validateJson } from "zttp:validate";

structural Guardrails<T> = Proof<T, "result_safe" | "optional_safe" | "deterministic">;

function handler(req: Request): Guardrails<Response> {
    const result = validateJson("item", req.body ?? "");
    if (!result.ok) {
        return Response.json({ error: result.error }, { status: 400 });
    }
    return Response.json({ data: result.value });
}
