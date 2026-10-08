// Proves: a typeof comparison whose answer the type already fixes is reported (ZTS107).
const n = 1;
const same = typeof n === "number";

function handler(req: Request): Proof<Response, "deterministic"> {
    return Response.text(String(same));
}
