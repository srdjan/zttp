// Proves: an identifier outside the closed ambient namespace is refused (ZTS629).
function handler(req: Request): Proof<Response, "deterministic"> {
    const count = globalThis;
    return Response.json({ count: 1 });
}
