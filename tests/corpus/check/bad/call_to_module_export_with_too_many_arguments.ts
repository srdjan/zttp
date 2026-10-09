// Proves: a call to a `zttp:*` export with more arguments than the export declares is refused (ZTS202), the same as a call to a source function.
import { sha256 } from "zttp:crypto";

function handler(req: Request): Proof<Response, "deterministic"> {
    const digest = sha256("payload", "extra");
    return Response.text(digest);
}
