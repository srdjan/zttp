import { run } from "zttp:durable";
import { call, saga } from "zttp:workflow";
import type { Spec } from "zttp:types";

structural SagaGuarantees = Spec<
    | "deterministic"
    | "state_isolated"
    | "result_safe"
    | "optional_safe"
    | "no_secret_leakage"
    | "no_credential_leakage"
    | "pii_contained"
    | "injection_safe"
    | "canonical"
>;

function handler(req: Request): Response & SagaGuarantees {
    const key = req.headers.get("idempotency-key") ?? "order-saga-demo";
    return run(key, () => {
        const outcome = saga([
            {
                name: "reserve",
                run: () => call("inventory", { method: "POST", path: "/reserve", body: req.body }),
                compensate: () => call("inventory", { method: "POST", path: "/release", body: req.body }),
            },
            {
                name: "charge",
                run: () => call("billing", { method: "POST", path: "/charge", body: req.body }),
                compensate: () => call("billing", { method: "POST", path: "/refund", body: req.body }),
            },
            {
                name: "ship",
                run: () => call("shipping", { method: "POST", path: "/ship", body: req.body }),
            },
        ]);
        return Response.json({ saga: "complete", outcome: outcome });
    });
}
