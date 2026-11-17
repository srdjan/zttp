// Proves: a numeric condition inside an arrow callback in `handler` is refused (ZTS100).
function handler(req: Request): Proof<Response, "deterministic"> {
    const xs: number[] = [4];
    const twice = xs.map((n: number): number => {
        if (n) {
            return 2;
        }
        return 0;
    });
    return Response.json({ b: twice });
}
