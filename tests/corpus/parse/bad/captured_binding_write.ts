// Proves: an arrow that assigns a binding of its enclosing function is refused (ZTS073).
function total(xs: number[]): number {
    let sum = 0;
    const ys = xs.map((x: number): number => {
        sum = sum + x;
        return x;
    });
    return sum + ys.length;
}

function handler(req: Request): Response {
    return Response.text(String(total([1, 2])));
}
