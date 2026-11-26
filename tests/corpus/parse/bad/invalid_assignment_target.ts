// Proves: assigning to a non-lvalue expression is refused (ZTS016).
function handler(req: Request): Response {
    let x: number = 0;
    (x) = 1;
    return Response.text("ok");
}
