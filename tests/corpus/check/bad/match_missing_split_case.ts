// Proves: when split arms leave one combination of two boolean fields uncovered, the help names that combination (ZTS603).
structural Flags = { x: boolean, y: boolean };

function describe(f: Flags): string | undefined {
    const out = match (f) {
        when { x: true, y: true }: "both"
        when { x: true, y: false }: "x only"
        when { x: false, y: true }: "y only"
    };
    return out;
}

function handler(req: Request): Proof<Response, "deterministic"> {
    const flags: Flags = { x: true, y: false };
    return Response.json({ out: describe(flags) });
}
