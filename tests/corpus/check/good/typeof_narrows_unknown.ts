// Proves: a typeof test over an unknown value narrows it to the named primitive in the guarded branch.
const flagOf = (v: unknown): number => {
    if (typeof v === "boolean") {
        if (v) { return 1; }
    }
    if (typeof v !== "number") { return 0; }
    return v;
};

function handler(req: Request): Proof<Response, "deterministic"> {
    return Response.json({ out: flagOf(true) });
}
