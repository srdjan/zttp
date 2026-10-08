// Proves: a recursive alias whose cycle runs through a union only is refused (ZTS212).
structural U = number | U;

function handler(req: Request): Proof<Response, "deterministic"> {
    const u: U = 1;
    return Response.json({ u: u });
}
