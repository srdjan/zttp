// Proves: a binding-only record arm does not cover the string member of the type (ZTS603).
structural Mixed = string | { w: number };

function describe(m: Mixed): string | undefined {
    const out = match (m) {
        when { w }: "record"
    };
    return out;
}

function handler(req: Request): Proof<Response, "deterministic"> {
    const value: Mixed = "s";
    return Response.json({ out: describe(value) });
}
