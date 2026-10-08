// Proves: a comparison with undefined on a value that is never undefined is reported (ZTS107).
const n = 1;
const missing = n === undefined;

function handler(req: Request): Proof<Response, "deterministic"> {
    return Response.text(String(missing));
}
