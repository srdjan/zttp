// Proves: an argument whose type does not match the parameter type is refused (ZTS203).
function double(x: number): number {
    return x + x;
}

function handler(req: Request): Proof<Response, "deterministic"> {
    const n = double("a");
    return Response.text(String(n));
}
