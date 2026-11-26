// Proves: `break` outside a loop is refused (ZTS022).
function handler(req: Request): Response {
    break;
    return Response.text("ok");
}
