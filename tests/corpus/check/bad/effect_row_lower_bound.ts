import { assert } from "zttp:core";
// Proves: a call through a value the compiler cannot resolve makes the effect row a lower bound (ZTS512).
// A declaration cannot hold a function value (ZTS217), so the call goes
// through an array element.
import { sha256 } from "zttp:crypto";

function digest(): string {
    return sha256("zttp");
}

function handler(req: Request): Proof<Effects<Response, "crypto">, "fault_covered"> {
    const fs = [digest];
    const made = fs[0]();
    assert(made.length >= 0);
    return Response.text("ok");
}
