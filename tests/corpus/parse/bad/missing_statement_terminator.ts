// Proves: a statement without a terminating semicolon is refused, there is no automatic insertion (ZTS047).
function handler(req: Request): Response {
    const label = "ok"
    return Response.text(label);
}
