// Proves: a secret read from env and sent in an outbound request header is refused (ZTS404).
// The check also reports ZTS406 for the same call; the golden pins both.
import { env } from "zttp:env";
import { fetch } from "zttp:fetch";

function handler(req: Request): Proof<Response, "deterministic"> {
    const token = env("SECRET_KEY") ?? "";
    const r = fetch("https://api.example.com/v1", { headers: { "x-tag": token } });
    return Response.json({ s: r.status });
}
