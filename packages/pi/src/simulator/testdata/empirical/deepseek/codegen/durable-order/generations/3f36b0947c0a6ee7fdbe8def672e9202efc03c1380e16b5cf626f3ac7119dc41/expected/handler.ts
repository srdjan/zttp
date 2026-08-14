import { run, step } from "zttp:durable";
import type { Spec } from "zttp:types";

structural OrderWorkflowGuarantees = Spec<
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

function handler(req: Request): Response & OrderWorkflowGuarantees {
    const key = req.headers.get("idempotency-key") ?? "order-workflow-demo";
    return run(key, () => {
        const reserved = step("reserve", () => {
            return { orderId: key, status: "reserved" };
        });
        const charged = step("charge", () => {
            return { orderId: key, status: "charged" };
        });
        return Response.json({
            workflow: "reserve-then-charge",
            runKey: key,
            reserve: reserved,
            charge: charged,
        });
    });
}
