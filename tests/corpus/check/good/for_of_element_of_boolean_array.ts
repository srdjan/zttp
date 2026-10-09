// Proves: the element variable of for-of over a boolean array is typed boolean.
const firstSet = (flags: boolean[]): number => {
    for (const flag of flags) {
        if (flag) { return 1; }
    }
    return 0;
};

function handler(req: Request): Proof<Response, "deterministic"> {
    return Response.json({ out: firstSet([false, true]) });
}
