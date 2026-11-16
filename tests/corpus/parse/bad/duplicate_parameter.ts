// Proves: a second parameter of one name is refused (ZTS018).
function pair(a: number, a: number): number {
    return a;
}

function handler(req: Request): Response {
    return Response.text(String(pair(1, 2)));
}
