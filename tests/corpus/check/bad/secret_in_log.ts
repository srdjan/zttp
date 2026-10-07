// Proves: a secret-labelled value passed to a log call is refused (ZTS402).
import { env } from "zttp:env";
import { logInfo } from "zttp:log";

function handler(req: Request): Proof<Response, "deterministic"> {
    const token = env("API_TOKEN") ?? "";
    logInfo(token, { n: 1 });
    if (token === "") { return Response.json({ ok: 0 }); }
    return Response.json({ ok: 1 });
}
