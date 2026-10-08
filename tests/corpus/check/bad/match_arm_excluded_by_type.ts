// Proves: an arm that the matched type excludes is reported as unreachable (ZTS216, a warning).
function describe(s: "a" | "b"): string {
    return match (s) {
        when "a": "first"
        when "b": "second"
        when "z": "never"
    };
}

function handler(req: Request): Proof<Response, "deterministic"> {
    return Response.json({ out: describe("a") });
}
