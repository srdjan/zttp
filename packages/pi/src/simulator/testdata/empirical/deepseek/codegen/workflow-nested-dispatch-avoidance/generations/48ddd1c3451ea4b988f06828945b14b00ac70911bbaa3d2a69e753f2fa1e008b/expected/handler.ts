import { run, step } from "zttp:durable";
import { call } from "zttp:workflow";
import { sha256 } from "zttp:crypto";
import { schemaCompile } from "zttp:validate";
import { decodeJson } from "zttp:decode";
import type { Spec } from "zttp:types";

schemaCompile("order", JSON.stringify({
    type: "object",
    required: ["sku", "quantity"],
    properties: {
        sku: { type: "string", minLength: 1 },
        quantity: { type: "number", minimum: 1 },
    },
}));

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
    const key = req.headers.get("idempotency-key") ?? "order-workflow";
    const body = req.body;
    if (body === undefined) return Response.json({ error: "body required" }, { status: 400 });
    const parsed = decodeJson("order", body);
    if (!parsed.ok) return Response.json({ error: parsed.errors }, { status: 400 });
    return run(key, () => {
        const reservation = step("reserve-inventory", () => {
            const reservationId = sha256(key + ":" + parsed.value.sku + ":" + parsed.value.quantity);
            return { reservationId: reservationId, sku: parsed.value.sku, quantity: parsed.value.quantity, status: "reserved" };
        });
        const notify = call("notify", {
            method: "POST",
            path: "/notify",
            body: { reservation: reservation, runKey: key },
        });
        return Response.json({
            runKey: key,
            reservationId: reservation.reservationId,
            status: reservation.status,
            notifyStatus: notify.status,
        });
    });
}
