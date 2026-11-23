import { match } from "zttp:core";
// Proves: a default arm after full coverage of a closed type is reported as unreachable (ZTS216, a warning).
function describe(s: "a" | "b"): string {
    return match(s)
        .with("a", () => "first")
        .with("b", () => "second")
        .otherwise(() => "other");
}

function handler(req: Request): Proof<Response, "deterministic"> {
    return Response.json({ out: describe("a") });
}
