// Proves: an assignment to a parameter is refused (ZTS068).
function next(n: number): number {
    n = n + 1;
    return n;
}

function handler(req: Request): Response {
    return Response.text(String(next(1)));
}
