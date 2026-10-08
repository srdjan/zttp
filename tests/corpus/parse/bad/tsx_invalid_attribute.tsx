// Proves: a JSX attribute with no value after `=` is refused (ZTS034).
function handler(req: Request): Response {
    return Response.html(<div class=>x</div>);
}
