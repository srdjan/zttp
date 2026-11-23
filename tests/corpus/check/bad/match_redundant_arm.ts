import { match } from "zttp:core";
// Proves: an arm that an earlier arm already matches is reported as unreachable (ZTS216, a warning).
function describe(s: "a" | "b"): string {
    return match(s)
        .with("a", () => "first")
        .with("a", () => "again")
        .with("b", () => "second")
        .exhaustive();
}

function handler(req: Request): Proof<Response, "deterministic"> {
    return Response.json({ out: describe("a") });
}
