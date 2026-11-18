// Proves: a declaration that holds a function value is refused (ZTS217).
function helper(x: string): string {
    return x;
}

function handler(req: Request): Response {
    const tag = helper;
    return Response.text(tag("a"));
}
