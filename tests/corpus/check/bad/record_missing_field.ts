// Proves: a record literal missing a declared field is refused by the type checker.
structural Point = { x: number, y: number };

function handler(req: Request): Proof<Response, "deterministic"> {
    const p: Point = { x: 1 };
    return Response.json({ p: p });
}
