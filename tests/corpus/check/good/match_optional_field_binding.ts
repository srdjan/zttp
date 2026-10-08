// Proves: an optional field is covered by a literal arm and a binding arm, because a binding also matches an absent field.
structural Opt = { a?: string };

function describe(o: Opt): string {
    return match (o) {
        when { a: "x" }: "x"
        when { a }: "other"
    };
}

function handler(req: Request): Proof<Response, "deterministic"> {
    const value: Opt = {};
    return Response.json({ out: describe(value) });
}
