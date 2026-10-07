// Proves: a default parameter value is refused (ZTS054).
function greet(name: string = "world"): string {
    return name;
}

function handler(req: Request): Response {
    return Response.text(greet("a"));
}
