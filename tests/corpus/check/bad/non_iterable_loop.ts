// Proves: a for...of over a value that is not an array, a tuple, or range(n) is refused (ZTS218).
function handler(req: Request): Response {
    const point = { x: 1, y: 2 };
    for (const v of point) {
        const n = v;
    }
    return Response.text("ok");
}
