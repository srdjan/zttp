// Proves: a Proof capsule naming a property outside the closed set is refused (ZTS502).
function handler(req: Request): Proof<Response, "banana"> {
    return Response.json({ ok: 1 });
}
