// Proves: the optional parameter shorthand `x?: T` is refused, write `T | undefined` (ZTS055).
function greet(name?: string): string {
    return name ?? "world";
}

function handler(req: Request): Response {
    return Response.text(greet("a"));
}
