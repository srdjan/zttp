// Proves: a tuple arm set that misses one element combination is refused (ZTS603), and the help spells it.
structural Pair = [boolean, "p" | "q"];

function describe(p: Pair): string | undefined {
    const out = match (p) {
        when [true, "p"]: "true-p"
        when [false, _]: "false"
    };
    return out;
}

function handler(req: Request): Proof<Response, "deterministic"> {
    const pair: Pair = [true, "p"];
    return Response.json({ out: describe(pair) });
}
