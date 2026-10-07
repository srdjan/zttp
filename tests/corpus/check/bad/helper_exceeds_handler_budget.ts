// Proves: a helper that reaches a capability outside the handler's Effects budget is refused (ZTS607).
import { logInfo } from "zttp:log";

function note(): string {
    logInfo("hit", { n: 1 });
    return "ok";
}

function handler(req: Request): Proof<Effects<Response, "clock">, "deterministic"> {
    return Response.text(note());
}
