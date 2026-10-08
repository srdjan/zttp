// Proves: a missing nested discriminant is refused (ZTS603), and the help spells the nested case.
structural Nested =
    | { k: "x", inner: { t: "p" } | { t: "q" } }
    | { k: "y" };

function describe(n: Nested): string | undefined {
    const out = match (n) {
        when { k: "x", inner: { t: "p" } }: "x-p"
        when { k: "y" }: "y"
    };
    return out;
}

function handler(req: Request): Proof<Response, "deterministic"> {
    const value: Nested = { k: "y" };
    return Response.json({ out: describe(value) });
}
