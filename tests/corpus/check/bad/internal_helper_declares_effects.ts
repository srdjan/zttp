// Proves: a module-internal helper that declares an Effects ceiling is refused, only exported helpers declare one (ZTS623).
import { sha256 } from "zttp:crypto";

function digest(text: string): Effects<string, "crypto"> {
    return sha256(text);
}

function handler(req: Request): Proof<Effects<Response, "crypto">, "deterministic"> {
    return Response.text(digest("a"));
}
