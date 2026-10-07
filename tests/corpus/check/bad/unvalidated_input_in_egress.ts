// Proves: request input that was never validated and reaches an outbound call is refused (ZTS407).
import { fetch } from "zttp:fetch";

function handler(req: Request): Proof<Response, "deterministic"> {
    const r = fetch("https://api.example.com/v1", { method: "POST", body: req.body ?? "" });
    return Response.json({ s: r.status });
}
