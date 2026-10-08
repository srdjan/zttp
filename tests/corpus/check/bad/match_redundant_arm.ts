// Proves: an arm that an earlier arm already matches is reported as unreachable (ZTS216, a warning).
function describe(s: "a" | "b"): string {
    return match (s) {
        when "a": "first"
        when "a": "again"
        when "b": "second"
    };
}

function handler(req: Request): Proof<Response, "deterministic"> {
    return Response.json({ out: describe("a") });
}
