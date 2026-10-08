// Proves: a refused string addition is reported once (ZTS105), not again as a type mismatch where its value is used.
function handler(req: Request): Proof<Response, "deterministic"> {
    const n: number = 1;
    const m: number = n + "y";
    return Response.text(String(m));
}
