// Proves: an environment value labelled secret that reaches a response body is refused (ZTS400).
import { env } from "zttp:env";

function handler(req: Request): Proof<Response, "deterministic"> {
    const token = env("API_TOKEN") ?? "";
    return Response.json({ token: token });
}
