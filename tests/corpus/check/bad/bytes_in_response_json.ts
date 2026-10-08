// Proves: a Bytes value in a Response.json payload is refused, because JSON cannot carry it (ZTS213).
function handler(req: Request): Proof<Response, "deterministic"> {
    return Response.json({ raw: requestBody(req) });
}
