// Proves: a conditional expression nested in a conditional arm is refused (ZTS621).
function handler(req: Request): Proof<Response, "deterministic"> {
    const a = true;
    const b = false;
    const tier = a ? 1 : b ? 2 : 3;
    return Response.json({ tier: tier });
}
