// Proves: a JSX element that is never closed is refused (ZTS035).
function handler(req: Request): Response {
    return Response.html(<div>x);
}
