// Proves: exact-length array arms never cover an array of unbounded length, so a default is required (ZTS603).
function describe(xs: number[]): string | undefined {
    const out = match (xs) {
        when []: "empty"
        when [_]: "one"
    };
    return out;
}

function handler(req: Request): Proof<Response, "deterministic"> {
    return Response.json({ out: describe([1, 2]) });
}
