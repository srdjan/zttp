// Proves: a call with more arguments than the callee declares is refused by the type checker.
function double(x: number): number {
    return x + x;
}

function handler(req: Request): Proof<Response, "deterministic"> {
    const n = double(1, 2);
    return Response.text(String(n));
}
