// Proves: a helper that breaks a property the handler demands, with no capsule of its own, is refused (ZTS606).
function stamp(): string {
    return String(Date.now());
}

function handler(req: Request): Proof<Response, "deterministic"> {
    return Response.text(stamp());
}
