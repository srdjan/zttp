// Proves: a radix prefix with no digits is refused (ZTS012).
function handler(req: Request): Response {
    const n = 0x;
    return Response.text(String(n));
}
