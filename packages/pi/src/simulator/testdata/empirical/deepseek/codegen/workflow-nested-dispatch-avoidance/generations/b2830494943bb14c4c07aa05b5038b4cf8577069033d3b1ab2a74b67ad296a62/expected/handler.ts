// Durable order workflow: reserve inventory as a replayable durable step,
// then dispatch a notify child handler via workflow.call at step depth 0.
import { run, step } from "zttp:durable";
import { call } from "zttp:workflow";
import type { Spec } from "zttp:types";

structural OrderWorkflowGuarantees = Spec<
    | "deterministic"
    | "state_isolated"
    | "no_secret_leakage"
    | "no_credential_leakage"
    | "input_validated"
    | "pii_contained"
    | "injection_safe"
>;

function handler(req: Request): Response & OrderWorkflowGuarantees {
    const key = req.headers.get("idempotency-key") ?? "order-workflow-demo";
    return run(key, () => {
        const reservation = step("reserve_inventory", () => {
            return { sku: "SKU-100", quantity: 1, reserved: true };
        });
        const res = call("notify", {
            method: "POST",
            path: "/notify",
            body: { orderId: key, reserved: reservation },
        });
        return Response.json({
            orderWorkflow: true,
            runKey: key,
            childBoundary: "workflow.call:notify",
            subStatus: res.status,
        });
    });
}
