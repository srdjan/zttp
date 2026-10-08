// Proves: the retired `zttp:types` import is refused, because Proof and Effects are ambient names (ZTS053).
import type { Spec } from "zttp:types";

function handler(req: Request): Response {
    return Response.text("ok");
}
