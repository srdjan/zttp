// Proves: a declaration with an empty initializer is refused with an expected-expression error (ZTS002).
function handler(req: Request): Response {
    const x = ;
    return Response.text("ok");
}
