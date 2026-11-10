// Proves: a headers member in a Response helper init is refused, because the runtime sends only the status of an init (ZTS203).
function handler(req: Request): Proof<Response, "deterministic"> {
    return Response.json({ ok: true }, { status: 201, headers: { "x-request-id": "r-1" } });
}
