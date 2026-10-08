// Proves: tuple arms of the exact length cover a tuple type, and an element underscore is a plain wildcard.
structural Pair = [boolean, "p" | "q"];

function describe(p: Pair): string {
    return match (p) {
        when [true, "p"]: "true-p"
        when [true, "q"]: "true-q"
        when [false, _]: "false"
    };
}

function handler(req: Request): Proof<Response, "deterministic"> {
    const pair: Pair = [true, "p"];
    return Response.json({ out: describe(pair) });
}
