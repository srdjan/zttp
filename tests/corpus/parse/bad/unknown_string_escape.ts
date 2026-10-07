// Proves: an escape outside the closed escape set is refused (ZTS013).
function handler(req: Request): Response {
    return Response.text("a\qb");
}
