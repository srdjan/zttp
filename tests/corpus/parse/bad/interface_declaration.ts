// Proves: an `interface` declaration is refused in favor of `structural` (ZTS049).
interface Shape { a: number }

function handler(req: Request): Response {
    return Response.text("ok");
}
