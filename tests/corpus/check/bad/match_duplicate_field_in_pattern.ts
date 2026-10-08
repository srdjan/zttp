// Proves: a pattern that names one field twice is not modelled, so the match is not proved exhaustive without a default (ZTS603).
structural Cmd = { kind: "a" } | { kind: "b" };

function describe(c: Cmd): string | undefined {
    const out = match (c) {
        when { kind: "a", kind: "b" }: "never"
    };
    return out;
}

function handler(req: Request): Proof<Response, "deterministic"> {
    const cmd: Cmd = { kind: "b" };
    return Response.json({ out: describe(cmd) });
}
