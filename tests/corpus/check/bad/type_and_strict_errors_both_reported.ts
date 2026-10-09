// Proves: a type error and a strict error on different expressions are both reported (ZTS105 and ZTS601), not only the type stage's.
function handler(req: Request) {
    const n: number = 1;
    const m: number = n + "y";
    return Response.text(String(m));
}
