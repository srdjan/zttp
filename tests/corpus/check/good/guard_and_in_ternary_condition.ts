// Proves: the guard on the left of && also types the right operand in a ternary condition.
const pick = (v: boolean | undefined): number => {
    return v !== undefined && v ? 1 : 0;
};

function handler(req: Request): Proof<Response, "deterministic"> {
    return Response.json({ out: pick(true) });
}
