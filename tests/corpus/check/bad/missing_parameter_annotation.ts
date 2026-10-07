// Proves: a function parameter without a type annotation is refused (ZTS601).
function scale(x): number {
    return x + x;
}

function handler(req: Request): Proof<Response, "deterministic"> {
    const v = scale(1);
    return Response.json({ v: v });
}
