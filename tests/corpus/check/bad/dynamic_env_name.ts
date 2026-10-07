// Proves: a capability call whose argument is computed from the request is refused (ZTS602).
import { env } from "zttp:env";

function handler(req: Request): Proof<Response, "deterministic"> {
    const key = req.url;
    const v = env(key) ?? "x";
    return Response.json({ v: v });
}
