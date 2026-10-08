// Proves: type tests do not cover a record member (ZTS603), and a test for a kind the type lacks is unreachable (ZTS216).
structural Mixed = string | { w: number };

function describe(m: Mixed): string | undefined {
    const out = match (m) {
        when string: "text"
        when number: "count"
    };
    return out;
}

function handler(req: Request): Proof<Response, "deterministic"> {
    const value: Mixed = "s";
    return Response.json({ out: describe(value) });
}
