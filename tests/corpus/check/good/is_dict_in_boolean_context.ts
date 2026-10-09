// Proves: the isDict and isBytes intrinsic guards are booleans in an if condition, a ternary, and a ! or && operand.
const classify = (doc: unknown): number => {
    const flat = !isDict(doc);
    const both = isDict(doc) && isBytes(doc);
    if (isDict(doc) || flat) { return 1; }
    return both || isBytes(doc) ? 2 : 3;
};

function handler(req: Request): Proof<Response, "deterministic"> {
    return Response.json({ out: classify(1) });
}
