import { schemaCompile, validateJson } from "zttp:validate";
import type { Spec } from "zttp:types";

schemaCompile(
    "item",
    JSON.stringify({
        type: "object",
        required: ["name"],
        properties: {
            name: { type: "string" },
        },
    })
);

structural ItemSpec = Spec<
    | "deterministic"
    | "read_only"
    | "retry_safe"
    | "idempotent"
    | "state_isolated"
    | "injection_safe"
    | "fault_covered"
>;

function handler(req: Request): Response & ItemSpec {
    const body = req.body ?? "";
    const result = validateJson("item", body);
    if (!result.ok) {
        return Response.json({ errors: result.errors }, { status: 400 });
    }
    return Response.json(result.value);
}
