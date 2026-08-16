import { run, step } from "zttp:durable";

structural OrderWorkflowProof<T> = Proof<T,
    "deterministic" | "retry_safe" | "idempotent" | "state_isolated" |
    "result_safe" | "no_secret_leakage" | "no_credential_leakage">;

export function handler(req: Request): OrderWorkflowProof<Response> {
    const key: string | undefined = req.headers.get("idempotency-key");
    if (key === undefined) {
        return Response.json({ error: "missing idempotency-key header" }, { status: 400 });
    }
    return run(key, () => {
        const reservation = step("reserve", () => ({
            ok: true,
            reservationId: ["res-", key].join(""),
        }));
        if (!reservation.ok) {
            return Response.json({ error: "inventory reservation failed" }, { status: 409 });
        }
        const charge = step("charge", () => ({
            ok: true,
            chargeId: ["chg-", reservation.reservationId].join(""),
        }));
        if (!charge.ok) {
            return Response.json({ error: "payment charge failed" }, { status: 402 });
        }
        return Response.json({
            orderId: key,
            reserved: true,
            charged: true,
            reservationId: reservation.reservationId,
            chargeId: charge.chargeId,
        }, { status: 201 });
    });
}
