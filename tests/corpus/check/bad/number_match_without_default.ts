// Proves: a match over a number with only literal arms is refused as non-exhaustive (ZTS603).
function handler(req: Request): Proof<Response, "deterministic"> {
    const n = 3;
    const out = match (n) {
        when 1: "one"
        when 2: "two"
    };
    return Response.json({ out: out });
}
