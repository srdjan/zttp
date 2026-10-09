// Proves: a type error and a boolean error on different expressions are both reported (ZTS105 and ZTS100), not only the first stage's.
function handler(req: Request): Proof<Response, "deterministic"> {
    const n: number = 1;
    const m: number = n + "y";
    if (5) {
        return Response.text("a");
    }
    return Response.text(String(m));
}
