import { run, waitSignal, signal } from "zttp:durable";
import type { Spec } from "zttp:types";

structural ApprovalGuarantees = Spec<
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

function handler(req: Request): Response & ApprovalGuarantees {
    const key = req.headers.get("idempotency-key") ?? "approval-default";

    if (req.method === "GET" && req.path === "/wait") {
        return run(key, () => {
            const decision = waitSignal("approval");
            return Response.json({ status: "approved", decision: decision });
        });
    }

    if (req.method === "POST" && req.path === "/signal") {
        if (req.body === undefined) {
            return Response.json({ error: "approval payload required" }, { status: 400 });
        }
        const payload = JSON.parse(req.body);
        const delivered = signal(key, "approval", payload);
        return Response.json({ status: delivered ? "signaled" : "not-parked", key: key });
    }

    return Response.json({ error: "not found" }, { status: 404 });
}
