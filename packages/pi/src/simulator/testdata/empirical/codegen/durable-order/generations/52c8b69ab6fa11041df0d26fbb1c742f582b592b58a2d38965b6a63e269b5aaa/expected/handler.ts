// Order workflow handler
// Two durable steps: reserve inventory, then charge payment.
// Run key comes from Idempotency-Key header so retries are safe.
import { run, step } from "zttp:durable";
import { fetch } from "zttp:fetch";
import { decodeJson } from "zttp:decode";
import { schemaCompile, validateJson } from "zttp:validate";
import { logInfo, logError } from "zttp:log";
import type { Spec } from "zttp:types";

schemaCompile("order", JSON.stringify({
    type: "object",
    required: ["orderId", "amount", "currency"],
    properties: {
        orderId:  { type: "string", minLength: 1 },
        amount:   { type: "number", minimum: 1 },
        currency: { type: "string", minLength: 3 }
    }
}));

schemaCompile("reserveResponse", JSON.stringify({
    type: "object",
    required: ["reservationId"],
    properties: {
        reservationId: { type: "string", minLength: 1 }
    }
}));

schemaCompile("chargeResponse", JSON.stringify({
    type: "object",
    required: ["chargeId"],
    properties: {
        chargeId: { type: "string", minLength: 1 }
    }
}));

// Step result shapes
type ReserveResult =
    | { ok: true;  reservationId: string }
    | { ok: false; reason: string };

type ChargeResult =
    | { ok: true;  chargeId: string }
    | { ok: false; reason: string };

type OrderWorkflowGuarantees = Spec<
    | "deterministic"
    | "state_isolated"
    | "result_safe"
    | "no_secret_leakage"
    | "no_credential_leakage"
    | "input_validated"
    | "injection_safe"
>;

function reserveStep(orderId: string, amount: number): ReserveResult {
    logInfo("reserve: starting", { orderId });
    const res = fetch("https://inventory.internal/reserve", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ orderId, amount })
    });
    if (res.status !== 200) {
        logError("reserve: failed", { status: res.status });
        return { ok: false, reason: "inventory unavailable" };
    }
    const parsed = validateJson("reserveResponse", res.body);
    if (!parsed.ok) {
        logError("reserve: invalid response", { errors: parsed.errors });
        return { ok: false, reason: "invalid reserve response" };
    }
    logInfo("reserve: done", { orderId });
    return { ok: true, reservationId: parsed.value.reservationId };
}

function chargeStep(orderId: string, reservationId: string, amount: number, currency: string): ChargeResult {
    logInfo("charge: starting", { orderId, reservationId });
    const res = fetch("https://payments.internal/charge", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ orderId, reservationId, amount, currency })
    });
    if (res.status !== 201) {
        logError("charge: failed", { status: res.status });
        return { ok: false, reason: "payment declined" };
    }
    const parsed = validateJson("chargeResponse", res.body);
    if (!parsed.ok) {
        logError("charge: invalid response", { errors: parsed.errors });
        return { ok: false, reason: "invalid charge response" };
    }
    logInfo("charge: done", { orderId });
    return { ok: true, chargeId: parsed.value.chargeId };
}

function handler(req: Request): Response & OrderWorkflowGuarantees {
    // Only accept POST
    if (req.method !== "POST") {
        return Response.json({ error: "method not allowed" }, { status: 405 });
    }

    // Validate and decode request body
    const body = req.body ?? "";
    const parsed = decodeJson("order", body);
    if (!parsed.ok) {
        return Response.json({ errors: parsed.errors }, { status: 400 });
    }

    const order = parsed.value;
    const runKey = req.headers.get("idempotency-key") ?? "order-" + order.orderId;

    return run(runKey, () => {
        // Step 1 – reserve inventory (snapshot replayed on recovery)
        const reservation: ReserveResult = step("reserve", () =>
            reserveStep(order.orderId, order.amount)
        );

        if (!reservation.ok) {
            return Response.json(
                { error: "reservation failed", reason: reservation.reason },
                { status: 502 }
            );
        }

        // Step 2 – charge payment (snapshot replayed on recovery)
        const charge: ChargeResult = step("charge", () =>
            chargeStep(order.orderId, reservation.reservationId, order.amount, order.currency)
        );

        if (!charge.ok) {
            return Response.json(
                { error: "charge failed", reason: charge.reason },
                { status: 402 }
            );
        }

        return Response.json({
            status:        "confirmed",
            orderId:       order.orderId,
            reservationId: reservation.reservationId,
            chargeId:      charge.chargeId
        }, { status: 201 });
    });
}
