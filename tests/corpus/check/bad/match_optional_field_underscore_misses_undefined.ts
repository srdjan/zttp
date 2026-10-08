// Proves: a field underscore fails on undefined, so it does not cover an absent optional field (ZTS603).
structural Opt = { a?: string };

function describe(o: Opt): string | undefined {
    const out = match (o) {
        when { a: "x" }: "x"
        when { a: _ }: "other"
    };
    return out;
}

function handler(req: Request): Proof<Response, "deterministic"> {
    const value: Opt = {};
    return Response.json({ out: describe(value) });
}
