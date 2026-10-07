// Proves: a byte above ASCII inside an identifier is refused (ZTS046).
function handler(req: Request): Response {
    const café = 2;
    return Response.text("ok");
}
