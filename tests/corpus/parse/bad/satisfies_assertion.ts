// Proves: a `satisfies` type assertion is refused (ZTS043).
function handler(req: Request): Response {
    const a = 1 satisfies number;
    return Response.text(String(a));
}
