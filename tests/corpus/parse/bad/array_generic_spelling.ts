// Proves: the `Array<T>` type spelling is refused in favor of `T[]` (ZTS058).
function handler(req: Request): Response {
    const xs: Array<number> = [1, 2];
    return Response.text(String(xs.length));
}
