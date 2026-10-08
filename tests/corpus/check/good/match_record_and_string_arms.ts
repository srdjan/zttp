// Proves: a binding-only record arm covers the record member only, so the string member needs its own arm.
structural Mixed = string | { w: number };

function describe(m: Mixed): string {
    return match (m) {
        when { w }: "record"
        when string: "text"
    };
}

function handler(req: Request): Proof<Response, "deterministic"> {
    const value: Mixed = "s";
    return Response.json({ out: describe(value) });
}
