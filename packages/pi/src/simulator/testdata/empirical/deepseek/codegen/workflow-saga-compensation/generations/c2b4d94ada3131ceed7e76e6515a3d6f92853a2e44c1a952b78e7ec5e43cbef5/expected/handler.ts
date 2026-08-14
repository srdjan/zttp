import { run } from "zttp:durable";
import { call, saga } from "zttp:workflow";
import type { Spec } from "zttp:types";

structural OrderSagaGuarantees = Spec<
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

function handler(req: Request): Response & OrderSagaGuarantees {
    const key = req.headers.get("idempotency-key") ?? "order-saga-demo";
    return run(key, () => {
        const outcome = saga([
            {
                name: "reserve",
                run: () => call("inventory", { method: "POST", path: "/reserve", body: { orderId: key } }),
                compensate: () => call("inventory", { method: "POST", path: "/release", body: { orderId: key } }),
            },
            {
                name: "charge",
                run: () => call("billing", { method: "POST", path: "/charge", body: { orderId: key } }),
                compensate: () => call("billing", { method: "POST", path: "/refund", body: { orderId: key } }),
            },
            {
                name: "ship",
                run: () => call("shipping", { method: "POST", path: "/ship", body: { orderId: key } }),
            },
        ]);
        return Response.json({
            saga: "reserve:charge:ship",
            runKey: key,
            compensation: "reserve:release, charge:refund",
            shipStatus: outcome.status,
        });
    });
}
