// Proves: a request credential sent in an outbound request header is refused (ZTS405).
// The check also reports ZTS407 twice for the unvalidated input; the golden pins all three.
import { fetch } from "zttp:fetch";

function handler(req: Request): Proof<Response, "deterministic"> {
    const auth = req.headers.authorization ?? "";
    const r = fetch("https://api.example.com/v1", { headers: { "x-tag": auth } });
    return Response.json({ s: r.status });
}
