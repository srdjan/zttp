import { run, step } from "zttp:durable";
import { call } from "zttp:workflow";

function reserveInventory(orderId: string): {
    orderId: string;
    sku: string;
    qty: number;
    status: string;
} {
    return { orderId: orderId, sku: "SKU-001", qty: 1, status: "reserved" };
}

function handler(req: Request): Proof<
    Response,
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
    | "cost_bounded"
> {
    const key = req.headers.get("idempotency-key") ?? "order-workflow";
    return run(key, () => {
        const reservation = step("reserve_inventory", () => reserveInventory(key));
        const notify = call("notify", {
            method: "POST",
            path: "/notify",
            body: { orderId: key, reservation: reservation },
        });
        return Response.json({
            orderId: key,
            reserved: true,
            childStatus: notify.status,
        });
    });
}
