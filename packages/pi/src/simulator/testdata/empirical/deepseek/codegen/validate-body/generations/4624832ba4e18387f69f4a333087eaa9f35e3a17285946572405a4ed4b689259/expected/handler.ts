import { schemaCompile, validateJson } from "zttp:validate";
import type { Spec } from "zttp:types";

structural ItemGuarantees = Spec<
    | "deterministic"
    | "read_only"
    | "retry_safe"
    | "idempotent"
    | "state_isolated"
    | "fault_covered"
    | "stateless"
    | "result_safe"
    | "optional_safe"
    | "no_secret_leakage"
    | "no_credential_leakage"
    | "input_validated"
    | "pii_contained"
    | "injection_safe"
    | "canonical"
    | "cost_bounded"
>;

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

function handler(req: Request): Response & ItemGuarantees {
    const result = validateJson("item", req.body ?? "");
    if (!result.ok) {
        return Response.json({ errors: result.errors }, { status: 400 });
    }
    return Response.json(result.value);
}
