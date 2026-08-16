import { run, step } from "zttp:durable";
import { call } from "zttp:workflow";
import { fetch } from "zttp:fetch";

structural OrderWorkflowProof<T> = Proof<T,
    | "deterministic"
    | "state_isolated"
    | "result_safe"
    | "optional_safe"
    | "no_secret_leakage"
    | "no_credential_leakage"
    | "canonical"
>;

export function handler(req: Request): OrderWorkflowProof<Response> {
    const key = req.headers.get("idempotency-key") ?? "order";
    return run(key, () => {
        const body = req.body ?? "{}";
        const reservation = step("reserve", () =>
            fetch("https://inventory.internal/reserve", {
                method: "POST",
                body: body
            })
        );
        if (!reservation.ok) {
            return Response.json({ error: "inventory reservation failed" }, { status: 502 });
        }
        const notify = call("notify", { method: "POST", path: "/notify" });
        return Response.json({ reserved: reservation.status, notified: notify.status }, { status: 201 });
    });
}
