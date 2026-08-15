// Should pass: result.ok checked before accessing .value
import { validateJson, schemaCompile } from "zttp:validate";

const ok = schemaCompile("test", JSON.stringify({ type: "object" }));

structural Guardrails<T> = Proof<T, "result_safe">;

function handler(req: Request): Guardrails<Response> {
    const result = validateJson("test", req.body ?? "");
    if (result.ok) {
        return Response.json({ data: result.value });
    }
    return Response.json({ error: result.error }, { status: 400 });
}
