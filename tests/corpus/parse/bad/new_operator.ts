// Proves: the `new` operator is refused at parse time.
function handler(req: Request): Response {
    const d = new Date();
    return Response.text("ok");
}
