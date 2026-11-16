// Proves: an assignment to a `const` binding is refused (ZTS066).
function handler(req: Request): Response {
    const n: number = 1;
    n = 2;
    return Response.text(String(n));
}
