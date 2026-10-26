// Proves: a handler that returns a bare Response, with no capsule, must prove the full default profile; this one reads the clock, so deterministic, idempotent, and pure fail (ZTS500).
function handler(req: Request): Response {
    return Response.json({ now: Date.now() });
}
