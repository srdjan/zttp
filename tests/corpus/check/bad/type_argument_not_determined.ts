// Proves: a type parameter that no argument determines is refused until the call names it (ZTS208).
function make<T>(n: number): T | undefined {
    return undefined;
}

function handler(req: Request): Proof<Response, "deterministic"> {
    const v = make(1);
    return Response.json({ v: v });
}
