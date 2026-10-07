// Proves: a reused non-callback arrow helper is refused in favor of a named function (ZTS608).
const double = (x: number): number => x + x;

function handler(req: Request): Proof<Response, "deterministic"> {
    const a = double(8);
    const b = double(9);
    return Response.json({ a: a, b: b });
}
