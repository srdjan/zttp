// Proves: surplus arguments are counted against the arrow's own parameter list, not against the annotations it happens to carry.
const first = (a: number, b): number => a;

function handler(req: Request): Proof<Response, "deterministic"> {
    const n = first(1, 2, 3);
    return Response.text(String(n));
}
