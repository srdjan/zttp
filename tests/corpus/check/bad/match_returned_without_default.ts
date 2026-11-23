import { match } from "zttp:core";
// Proves: a match returned straight from a function typed `string` that does not cover every case is refused as ZTS603, as in the statement and `const` positions, and ZTS205 stays only beside the ZTS204 of another function.
function describe(s: string): string {
    return match(s).with("a", () => "first").exhaustive();
}

function other(): number {
    return "x";
}

function handler(req: Request): Proof<Response, "deterministic"> {
    return Response.json({ out: describe("a"), n: other() });
}
