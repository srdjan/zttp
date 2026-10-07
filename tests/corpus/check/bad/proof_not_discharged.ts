// Proves: a declared deterministic capsule on a handler that reads the clock is refused (ZTS500).
function handler(req: Request): Proof<Response, "deterministic"> {
    const count = Date.now();
    return Response.json({ count: count });
}
