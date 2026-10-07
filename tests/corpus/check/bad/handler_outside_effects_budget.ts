// Proves: a handler that calls a capability outside its declared Effects budget is refused (ZTS506).
import { logInfo } from "zttp:log";

structural Narrow<T> = Proof<T,
    | "deterministic"
    | "state_isolated"
    | "result_safe"
    | "optional_safe"
    | "no_secret_leakage"
    | "no_credential_leakage"
    | "input_validated"
    | "injection_safe"
    | "canonical"
    | "cost_bounded"
>;

function handler(req: Request): Narrow<Effects<Response, "clock">> {
    logInfo("hit", { n: 1 });
    return Response.text("ok");
}
