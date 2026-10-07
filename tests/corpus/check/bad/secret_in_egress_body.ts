// Proves: a secret-labelled value sent as an outbound request body is refused (ZTS406).
import { env } from "zttp:env";
import { fetch } from "zttp:fetch";

function handler(req: Request): Proof<Response, "deterministic"> {
    const token = env("API_TOKEN") ?? "";
    const r = fetch("https://api.example.com/v1", { method: "POST", body: token });
    return Response.json({ s: r.status });
}
