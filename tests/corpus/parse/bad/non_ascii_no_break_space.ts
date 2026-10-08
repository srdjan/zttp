// Proves: U+00A0 NO-BREAK SPACE between two tokens is named, with an ASCII space as the repair (ZTS046).
function handler(req: Request): Response {
    const n = 5;
    const m = n + 1;
    return Response.text(String(m));
}
