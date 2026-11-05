// Proves: a helper that pushes onto its parameter, called with a module array, is a shared-state write (ZTS310).
const seen: number[] = [];

function addTo(xs: number[]): undefined {
    xs.push(1);
    return undefined;
}

function handler(req: Request): Proof<Response, "deterministic"> {
    addTo(seen);
    return Response.text(String(seen.length));
}
