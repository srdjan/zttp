// Proves: a discriminant test narrows the right operand of && to the matched member.
structural Ev = { kind: "a", flag: boolean } | { kind: "b", n: number };

const flagOf = (e: Ev): number => {
    const on = e.kind === "a" && e.flag;
    if (on) { return 1; }
    return 0;
};

function handler(req: Request): Proof<Response, "deterministic"> {
    const ev: Ev = { kind: "b", n: 1 };
    return Response.json({ out: flagOf(ev) });
}
