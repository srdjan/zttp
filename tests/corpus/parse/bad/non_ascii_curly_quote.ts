// Proves: a curly double quote that opens a string is named, with the ASCII quote as the repair (ZTS046).
function handler(req: Request): Response {
    const label = “ok”;
    return Response.text(label);
}
