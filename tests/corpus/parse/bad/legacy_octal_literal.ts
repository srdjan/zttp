// Proves: a legacy octal literal is refused, write `0o755` (ZTS012).
function handler(req: Request): Response {
    const mode = 0755;
    return Response.text(String(mode));
}
