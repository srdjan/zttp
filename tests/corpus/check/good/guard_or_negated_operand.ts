// Proves: the negated guard on the left of || types the right operand.
const missingOrOff = (v: boolean | undefined): number => {
    const off = v === undefined || !v;
    if (off) { return 1; }
    return 0;
};

function handler(req: Request): Proof<Response, "deterministic"> {
    return Response.json({ out: missingOrOff(true) });
}
