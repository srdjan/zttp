// Proves: a numeric condition inside a function declared in `handler`, and one in an arrow inside `handler`, are each refused (ZTS100).
function handler(req: Request): Proof<Response, "deterministic"> {
    function inner(n: number): number {
        if (n) {
            return 1;
        }
        return 0;
    }
    const twice = (n: number): number => {
        if (n) {
            return 2;
        }
        return 0;
    };
    return Response.json({ a: inner(3), b: twice(4) });
}
