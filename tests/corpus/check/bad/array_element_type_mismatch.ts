// Proves: an array literal whose elements do not match the declared element type is refused.
function handler(req: Request): Proof<Response, "deterministic"> {
    const xs: number[] = ["a"];
    return Response.json({ xs: xs });
}
