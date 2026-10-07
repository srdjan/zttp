// Proves: a workflow call inside a durable step callback is refused, it silently loses durability (ZTS509).
import { step } from "zttp:durable";
import { call } from "zttp:workflow";

function handler(req: Request): Proof<Response, "deterministic"> {
    step("s", () => call("billing", {}));
    return Response.text("ok");
}
