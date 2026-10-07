// Proves: an exported helper that reaches a capability without declaring an Effects ceiling is refused (ZTS610).
import { sha256 } from "zttp:crypto";

structural Digest = { hex: string };

export function digest(): Digest {
    return { hex: sha256("a") };
}

export function handler(req: Request): Proof<Effects<Response, "crypto">, "deterministic"> {
    const d = digest();
    return Response.text(d.hex);
}
