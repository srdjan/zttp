// Proves: `??` on a number that is never undefined is reported (ZTS103).
const n = 1;
const value = n ?? 2;

function handler(req: Request): Proof<Response, "deterministic"> {
    return Response.text(String(value));
}
