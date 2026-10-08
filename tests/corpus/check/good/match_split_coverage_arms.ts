// Proves: arms that split one case across a second field cover a closed record type with no default.
structural Flags = { x: boolean, y: boolean };

function describe(f: Flags): string {
    return match (f) {
        when { x: true, y: true }: "both"
        when { x: true, y: false }: "x only"
        when { x: false }: "no x"
    };
}

function handler(req: Request): Proof<Response, "deterministic"> {
    const flags: Flags = { x: true, y: false };
    return Response.json({ out: describe(flags) });
}
