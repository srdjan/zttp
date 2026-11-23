import { match } from "zttp:core";
// Proves: an arm that the matched type excludes is reported as unreachable (ZTS216, a warning).
function describe(s: "a" | "b"): string {
    return match(s)
        .with("a", () => "first")
        .with("b", () => "second")
        .with("z", () => "never")
        .exhaustive();
}

function handler(req: Request): Proof<Response, "deterministic"> {
    return Response.json({ out: describe("a") });
}
