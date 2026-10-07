// Proves: an Effects ceiling that is not a closed union of string literals is reported (ZTS511).
import { sha256 } from "zttp:crypto";

function handler(req: Request): Proof<Effects<Response, string>, "deterministic"> {
    return Response.text(sha256("zttp"));
}
