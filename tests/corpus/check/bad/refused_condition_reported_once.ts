// Proves: a condition that is itself a refused operator is reported once, as ZTS105; the boolean checker's ZTS100 for the same expression is dropped.
function handler(req: Request): Proof<Response, "deterministic"> {
    const n: number = 1;
    if (n + "y") {
        return Response.text("a");
    }
    return Response.text("b");
}
