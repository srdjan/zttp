// Proves: U+2212 MINUS SIGN outside an identifier is named and not blamed on an identifier (ZTS046).
function handler(req: Request): Response {
    const n = 5;
    const m = n − 1;
    return Response.text(String(m));
}
