// Proves: an `as` type assertion is refused by the stripper.
function handler(req: Request): Response {
    const x = "1" as string;
    return Response.text(x);
}
