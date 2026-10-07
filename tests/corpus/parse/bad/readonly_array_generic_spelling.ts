// Proves: the `ReadonlyArray<T>` type spelling is refused in favor of `readonly T[]` (ZTS059).
function handler(req: Request): Response {
    const xs: ReadonlyArray<number> = [1, 2];
    return Response.text(String(xs.length));
}
