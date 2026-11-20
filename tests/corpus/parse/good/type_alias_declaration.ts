// Proves: a standard type alias preserves structural field checking.
type Shape = { a: number };

function handler(req: Request): Response {
    const shape: Shape = { a: 1 };
    return Response.text(String(shape.a));
}
