// Proves: a read_only capsule on a handler that calls a writing module function is refused (ZTS501).
import { cacheSet } from "zttp:cache";

function handler(req: Request): Proof<Response, "read_only"> {
    cacheSet("ns", "k", "v");
    return Response.json({ v: "ok" });
}
