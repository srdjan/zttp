// Proves: a name that an enclosing scope declares is refused (ZTS069).
function total(n: number): number {
    const xs: number[] = [1, 2];
    const ys = xs.map((n: number): number => n + 1);
    return ys.length;
}

function handler(req: Request): Response {
    return Response.text(String(total(1)));
}
