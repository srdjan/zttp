// Proves: arithmetic on a string operand is refused (ZTS104).
const s = "a";
const diff = s - 1;

function handler(req: Request): Proof<Response, "deterministic"> {
    return Response.text(String(diff));
}
