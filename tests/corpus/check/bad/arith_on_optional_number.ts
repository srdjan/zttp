// Proves: arithmetic on a parameter declared `number | undefined` is refused with ZTS106, because the value can fault at runtime.
function inc(x: number | undefined): number {
    return x + 1;
}

function handler(req: Request): Proof<Response, "deterministic"> {
    return Response.json({ total: inc(undefined) });
}
