// Proves: an outbound fetch whose URL is computed from the request is refused (ZTS602).
import { fetch } from "zttp:fetch";

function handler(req: Request): Proof<Response, "deterministic"> {
    const target = req.url;
    const res = fetch(target);
    return Response.json({ status: res.status });
}
