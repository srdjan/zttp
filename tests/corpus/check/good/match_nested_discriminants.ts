// Proves: discriminants at two depths are covered arm by arm, so a union of nested records needs no default.
structural Nested =
    | { k: "x", inner: { t: "p" } | { t: "q" } }
    | { k: "y" };

function describe(n: Nested): string {
    return match (n) {
        when { k: "x", inner: { t: "p" } }: "x-p"
        when { k: "x", inner: { t: "q" } }: "x-q"
        when { k: "y" }: "y"
    };
}

function handler(req: Request): Proof<Response, "deterministic"> {
    const value: Nested = { k: "y" };
    return Response.json({ out: describe(value) });
}
