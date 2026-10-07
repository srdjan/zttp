// Proves: a credential-labelled value passed to a log call is refused (ZTS403).
import { logInfo } from "zttp:log";

function handler(req: Request): Proof<Response, "deterministic"> {
    const auth = req.headers.authorization ?? "";
    logInfo(auth, { n: 1 });
    if (auth === "") { return Response.json({ ok: 0 }); }
    return Response.json({ ok: 1 });
}
