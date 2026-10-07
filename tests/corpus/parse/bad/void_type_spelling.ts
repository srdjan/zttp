// Proves: the `void` type spelling is refused in favor of `undefined` (ZTS060).
function note(x: number): void {
    return undefined;
}

function handler(req: Request): Response {
    return Response.text("ok");
}
