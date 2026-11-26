// Proves: `continue` outside a loop is refused (ZTS023).
function handler(req: Request): Response {
    continue;
    return Response.text("ok");
}
