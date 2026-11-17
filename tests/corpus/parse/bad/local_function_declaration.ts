// Proves: a function declaration inside a function body is refused (ZTS071).
function handler(req: Request): Response {
    function inner(): number {
        return 1;
    }
    return Response.text(String(inner()));
}
