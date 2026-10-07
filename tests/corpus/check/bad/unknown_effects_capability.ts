// Proves: an Effects ceiling that names a capability the runtime does not have is refused (ZTS504).
function handler(req: Request): Proof<Effects<Response, "teleport">, "deterministic"> {
    return Response.text("ok");
}
