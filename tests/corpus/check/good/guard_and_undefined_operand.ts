// Proves: a boolean-context operand is typed under the left operand's guard.
const optionalFlag = (v: boolean | undefined): number => {
    const both = v !== undefined && v;
    if (both) { return 1; }
    return 0;
};

function handler(req: Request): Proof<Response, "deterministic"> {
    return Response.json({ out: optionalFlag(true) });
}
