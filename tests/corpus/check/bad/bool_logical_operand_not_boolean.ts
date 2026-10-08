// Proves: a number operand of `&&` is refused, because `&&` takes booleans (ZTS101).
const n = 1;
const both = n && true;

function handler(req: Request): Proof<Response, "deterministic"> {
    return Response.text(String(both));
}
