// Proves: a string literal that reaches the end of its line is refused with a location (ZTS008).
function handler(req: Request): Response {
    return Response.text("never closed);
}
