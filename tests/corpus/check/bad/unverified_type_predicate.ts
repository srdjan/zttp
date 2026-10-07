// Proves: a type predicate whose body is not an admitted narrowing test is refused (ZTS211).
function isBig(x: number): x is number {
    return x > 3;
}

function handler(req: Request): Proof<Response, "deterministic"> {
    return Response.text("ok");
}
