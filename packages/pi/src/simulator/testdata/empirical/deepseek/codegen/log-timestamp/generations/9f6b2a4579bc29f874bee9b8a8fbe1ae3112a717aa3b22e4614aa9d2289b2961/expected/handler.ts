import { logInfo } from "zttp:log";

structural HandlerGuarantees<T> = Proof<T,
    | "state_isolated"
    | "no_secret_leakage"
    | "no_credential_leakage"
    | "input_validated"
    | "pii_contained"
    | "injection_safe"
>;

export function handler(req: Request): HandlerGuarantees<Response> {
    const now: number = Date.now();
    logInfo(["served request at ", String(now)].join(""), {});
    return Response.json({ ok: true });
}
