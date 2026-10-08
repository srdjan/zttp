// Proves: a ternary condition of type number is refused, with no truthiness conversion (ZTS100).
const n = 1;
const picked = n ? "one" : "zero";

function handler(req: Request): Proof<Response, "deterministic"> {
    return Response.text(picked);
}
