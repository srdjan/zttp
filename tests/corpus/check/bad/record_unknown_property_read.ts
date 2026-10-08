// Proves: reading a property that the record type does not declare is refused (ZTS201).
structural Point = { x: number; y: number };

function handler(req: Request): Proof<Response, "deterministic"> {
    const p: Point = { x: 1, y: 2 };
    const z = p.z;
    return Response.text(String(z));
}
