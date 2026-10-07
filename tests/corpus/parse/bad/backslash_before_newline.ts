// Proves: a backslash before a real newline inside a string is refused (ZTS045).
function handler(req: Request): Response {
    const s = "a\
b";
    return Response.text(s);
}
