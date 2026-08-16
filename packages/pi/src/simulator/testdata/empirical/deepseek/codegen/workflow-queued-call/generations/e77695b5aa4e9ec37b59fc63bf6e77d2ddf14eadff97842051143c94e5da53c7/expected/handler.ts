import { run } from "zttp:durable";
import { call } from "zttp:workflow";

structural WorkflowGuarantees<T> = Proof<T,
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

export function handler(req: Request): WorkflowGuarantees<Response> {
    const key = req.headers.get("idempotency-key") ?? "workflow-demo";
    return run(key, () => {
        const child = call("greet", { method: "GET", path: "/workflow" });
        return Response.json({
            runKey: key,
            childBoundary: "workflow.call:greet",
            childStatus: child.status,
            child: child.json(),
        });
    });
}
