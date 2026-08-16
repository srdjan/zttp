import { run, waitSignal, signal } from "zttp:durable";
import { routerMatch } from "zttp:router";

structural ApprovalGuarantees<T> = Proof<T,
    | "deterministic"
    | "retry_safe"
    | "idempotent"
    | "state_isolated"
    | "no_secret_leakage"
    | "no_credential_leakage"
    | "input_validated"
    | "pii_contained"
    | "injection_safe"
>;

function waitForApproval(req: Request): Response {
    const key = req.headers.get("Idempotency-Key");
    if (key === undefined) {
        return Response.json({ error: "missing Idempotency-Key header" }, { status: 400 });
    }
    return run(key, () => {
        const approval = waitSignal("approval");
        return Response.json({ approved: approval !== undefined });
    });
}

function signalApproval(req: Request): Response {
    const key = req.headers.get("Idempotency-Key");
    if (key === undefined) {
        return Response.json({ error: "missing Idempotency-Key header" }, { status: 400 });
    }
    const delivered = signal(key, "approval", { approved: true });
    return Response.json({ delivered: delivered });
}

const routes = {
    "POST /wait": waitForApproval,
    "POST /signal": signalApproval,
};

function handler(req: Request): ApprovalGuarantees<Response> {
    const found = routerMatch(routes, req);
    if (found !== undefined) {
        req.params = found.params;
        return found.handler(req);
    }
    return Response.json({ error: "not found" }, { status: 404 });
}
