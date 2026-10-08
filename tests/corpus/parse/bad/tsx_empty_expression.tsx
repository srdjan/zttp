// Proves: an empty JSX expression container is refused (ZTS036).
function handler(req: Request): Response {
    return Response.html(<div>{}</div>);
}
