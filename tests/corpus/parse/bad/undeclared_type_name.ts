// Proves: a parameter annotation that names an undeclared type is refused at the name (ZTS065).
function handler(req: Widget): Response {
    return Response.text("ok");
}
