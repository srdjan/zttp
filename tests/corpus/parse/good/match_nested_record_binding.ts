// Proves: a nested record pattern that binds an inner field parses and passes every stage.
structural Inner = { b: string };
structural Outer = { a: Inner };

function handler(req: Request): Proof<Response, "deterministic"> {
    const input: Outer = { a: { b: "deep" } };
    const out = match (input) {
        when { a: { b: x } }: x
    };
    return Response.text(out);
}
