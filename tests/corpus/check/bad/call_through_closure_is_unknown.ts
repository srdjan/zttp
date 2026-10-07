// Proves: a call whose result has implicit unknown type is refused (ZTS600).
import { sha256 } from "zttp:crypto";

function handler(req: Request): Proof<Effects<Response, "crypto">, "deterministic"> {
    const f = () => sha256("zttp");
    return Response.text(f());
}
