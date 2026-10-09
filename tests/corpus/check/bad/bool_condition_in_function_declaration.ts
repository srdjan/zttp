// Proves: a numeric condition inside a declared function body is refused (ZTS100); the body of `handler` and of a helper are walked like module scope.
function pick(n: number): number {
    if (n) {
        return 1;
    }
    return 0;
}

function handler(req: Request): Proof<Response, "deterministic"> {
    return Response.json({ out: pick(3) });
}
