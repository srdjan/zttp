// Proves: a reserved word as a value name is refused (ZTS067).
function handler(req: Request): Response {
    const from = 1;
    return Response.text("ok");
}
