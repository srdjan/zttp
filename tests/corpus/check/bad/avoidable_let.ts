// Proves: a `let` binding that is never reassigned is refused (ZTS604).
function handler(req: Request): Proof<Response, "deterministic"> {
    let total = 5;
    return Response.json({ total: total });
}
