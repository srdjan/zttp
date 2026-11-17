// Proves: the body of an `if` that is not a block is refused (ZTS070).
function handler(req: Request): Response {
    if (req.method !== "GET") return Response.text("no", { status: 405 });
    return Response.text("ok");
}
