// Proves: `try`/`catch` is refused at parse time in favor of Result values.
function handler(req: Request): Response {
    try {
        return Response.text("ok");
    } catch (e) {
        return Response.text("failed");
    }
}
