// Proves: a match returned straight from a function typed `string` has type `string | undefined` (ZTS204), and ZTS205 still names the missing case because the type error ends the check before the strict stage.
function describe(s: string): string {
    return match (s) {
        when "a": "first"
    };
}

function handler(req: Request): Proof<Response, "deterministic"> {
    return Response.json({ out: describe("a") });
}
