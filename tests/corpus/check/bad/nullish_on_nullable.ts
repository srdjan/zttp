// Proves: `??` on an operand whose type admits null is refused (ZTS624).
structural MaybeName = string | null;

function nameOf(): MaybeName {
    return null;
}

function handler(req: Request): Proof<Response, "deterministic"> {
    const n = nameOf();
    const name = n ?? "anon";
    return Response.json({ name: name });
}
