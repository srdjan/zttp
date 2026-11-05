// Proves: a push two helper calls below the handler, onto a module array passed down, is a shared-state write (ZTS310).
const seen: number[] = [];

function addTo(xs: number[]): undefined {
    xs.push(1);
    return undefined;
}

function viaHelper(): undefined {
    addTo(seen);
    return undefined;
}

function handler(req: Request): Proof<Response, "deterministic"> {
    viaHelper();
    return Response.text(String(seen.length));
}
