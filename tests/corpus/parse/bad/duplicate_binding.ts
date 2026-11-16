// Proves: a second `const` of one name in one scope is refused (ZTS019).
function handler(req: Request): Response {
    const a = 1;
    const a = 2;
    return Response.text(String(a));
}
