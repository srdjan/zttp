// Proves: a JSX closing tag that does not match its opening tag is refused (ZTS033).
function handler(req: Request): Response {
    return Response.html(<div></span>);
}
