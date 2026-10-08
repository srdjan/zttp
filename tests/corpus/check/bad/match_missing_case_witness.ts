// Proves: a closed record union with one member uncovered is refused (ZTS603), and the help names that member.
structural Cmd =
    | { kind: "a", n: number }
    | { kind: "b" }
    | { kind: "c", t: string };

function describe(c: Cmd): string | undefined {
    const out = match (c) {
        when { kind: "a", n }: "a"
        when { kind: "b" }: "b"
    };
    return out;
}

function handler(req: Request): Proof<Response, "deterministic"> {
    const cmd: Cmd = { kind: "b" };
    return Response.json({ out: describe(cmd) });
}
