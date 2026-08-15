import { run } from "zttp:durable";
import { call } from "zttp:workflow";
import type { Spec } from "zttp:types";

structural WorkflowGuarantees = Spec<
    | "deterministic"
    | "state_isolated"
    | "result_safe"
    | "optional_safe"
    | "no_secret_leakage"
    | "no_credential_leakage"
    | "input_validated"
    | "pii_contained"
    | "injection_safe"
    | "canonical"
>;

function handler(req: Request): Response & WorkflowGuarantees {
    const key = req.headers.get("idempotency-key") ?? "workflow-demo";
    return run(key, () => {
        const child = call("greet", { method: "GET", path: "/greet" });
        return Response.json({ runKey: key, childStatus: child.status });
    });
}
