// Proves: the operand of `!` must be boolean, so `!n` on a number is refused (ZTS102).
const n = 1;
const flipped = !n;

function handler(req: Request): Proof<Response, "deterministic"> {
    return Response.text(String(flipped));
}
