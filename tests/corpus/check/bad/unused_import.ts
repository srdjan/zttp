// Proves: an import binding that is never used is reported (ZTS306).
import { env } from "zttp:env";

function handler(req: Request): Proof<Response, "deterministic"> {
    return Response.json({ ok: 1 });
}
