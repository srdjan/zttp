// Proves: an exported helper that reaches a capability outside its declared Effects ceiling is refused (ZTS503).
import { sha256 } from "zttp:crypto";

structural Digest = { hex: string };

export function digest(): Effects<Digest, "clock"> {
    return { hex: sha256("a") };
}

export function handler(req: Request): Proof<Effects<Response, "crypto" | "clock">, "deterministic"> {
    const d = digest();
    return Response.text(d.hex);
}
