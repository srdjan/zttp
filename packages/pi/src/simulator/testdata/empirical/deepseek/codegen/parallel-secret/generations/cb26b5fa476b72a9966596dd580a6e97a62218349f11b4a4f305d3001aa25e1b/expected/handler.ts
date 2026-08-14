import { env } from "zttp:env";
import { parallel } from "zttp:io";
import type { Spec } from "zttp:types";

structural HandlerGuarantees = Spec<
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
>;

function handler(req: Request): Response & HandlerGuarantees {
    const [, hasSecret] = parallel([
        () => env("APP_NAME"),
        () => env("API_SECRET") !== undefined,
    ]);
    if (!hasSecret) {
        return Response.json({ error: "server misconfigured" }, { status: 503 });
    }
    return Response.json({ appName: env("APP_NAME") });
}
