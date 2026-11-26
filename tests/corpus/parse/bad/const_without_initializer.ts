// Proves: a `const` declaration without an initializer is refused (ZTS021).
function handler(req: Request): Response {
    const x: number;
    return Response.text(String(x));
}
