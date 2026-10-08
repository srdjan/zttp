// Proves: `+` on a boolean operand is refused (ZTS106).
const sum = true + 1;

function handler(req: Request): Proof<Response, "deterministic"> {
    return Response.text(String(sum));
}
