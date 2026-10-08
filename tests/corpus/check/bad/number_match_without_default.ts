// Proves: a match over a number with only literal arms is refused as non-exhaustive (ZTS603), and the help names the missing case.
function describe(n: number): string | undefined {
    const out = match (n) {
        when 1: "one"
        when 2: "two"
    };
    return out;
}

function handler(req: Request): Proof<Response, "deterministic"> {
    return Response.json({ out: describe(3) });
}
