import { run } from "zttp:durable";
import { call, saga } from "zttp:workflow";

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
    const key = req.headers.get("idempotency-key") ?? "order-saga";
    return run(key, () => {
        const outcome = saga([
            {
                name: "reserve",
                run: () => call("inventory", { method: "POST", path: "/reserve" }),
                compensate: () => call("inventory", { method: "POST", path: "/release" }),
            },
            {
                name: "charge",
                run: () => call("billing", { method: "POST", path: "/charge" }),
                compensate: () => call("billing", { method: "POST", path: "/refund" }),
            },
            {
                name: "ship",
                run: () => call("shipping", { method: "POST", path: "/ship" }),
            },
        ]);
        return Response.json({ outcome: outcome });
    });
}
