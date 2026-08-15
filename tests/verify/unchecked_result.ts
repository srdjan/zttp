// Should fail: result.value accessed without checking result.ok
import { validateJson, schemaCompile } from "zttp:validate";

const ok = schemaCompile("test", JSON.stringify({ type: "object" }));

structural Guardrails<T> = Proof<T, "result_safe">;

function handler(req: Request): Guardrails<Response> {
    const result = validateJson("test", req.body ?? "");
    return Response.json({ data: result.value });
}
