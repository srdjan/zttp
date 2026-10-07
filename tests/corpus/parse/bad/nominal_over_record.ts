// Proves: a nominal declaration over a record base is refused, nominal carries scalar identity only (ZTS048).
nominal Bad = { a: number };

function handler(req: Request): Response {
    return Response.text("ok");
}
