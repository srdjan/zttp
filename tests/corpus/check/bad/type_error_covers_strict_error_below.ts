// Proves: a strict error inside an expression that already has a type error is not reported beside it; the call has a surplus argument (ZTS202) and the partly annotated arrow inside it (ZTS601) is dropped.
function one(a: number): number {
    return a;
}

function handler(req: Request): Proof<Response, "deterministic"> {
    const x: number = one(1, (a: number, b) => a);
    return Response.text(String(x));
}
