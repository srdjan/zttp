// Proves: a compound assignment operator is refused, write `x = x + e` (ZTS613).
function handler(req: Request): Proof<Response, "deterministic"> {
    let total = 1;
    total += 7;
    return Response.json({ total: total });
}
