// Proves: a `type` alias is refused in favor of `structural` (ZTS050).
type Shape = { a: number };

function handler(req: Request): Response {
    return Response.text("ok");
}
