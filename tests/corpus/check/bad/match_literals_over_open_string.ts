// Proves: string literal arms never cover string, so a default is required (ZTS603).
function describe(s: string): string | undefined {
    const out = match (s) {
        when "a": "first"
        when "b": "second"
    };
    return out;
}

function handler(req: Request): Proof<Response, "deterministic"> {
    return Response.json({ out: describe("a") });
}
