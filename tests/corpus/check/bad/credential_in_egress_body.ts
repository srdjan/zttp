// Proves: a request credential sent in an outbound request body is refused (ZTS408).
// The check also reports ZTS407 for the unvalidated input; the golden pins both.
import { fetch } from "zttp:fetch";

function handler(req: Request): Proof<Response, "deterministic"> {
    const auth = req.headers.authorization ?? "";
    const r = fetch("https://api.example.com/v1", { method: "POST", body: auth });
    return Response.json({ s: r.status });
}
