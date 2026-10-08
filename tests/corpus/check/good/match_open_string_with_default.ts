// Proves: literal arms over an open type are exhaustive with a default, and that default is not redundant.
function describe(s: string): string {
    return match (s) {
        when "a": "first"
        when "b": "second"
        default: "other"
    };
}

function handler(req: Request): Proof<Response, "deterministic"> {
    return Response.json({ out: describe("a") });
}
