// Proves: a handler that returns a bare Response, with no capsule, must prove the full default profile (ZTS500).
function handler(req: Request): Response {
    return Response.text("ok");
}
