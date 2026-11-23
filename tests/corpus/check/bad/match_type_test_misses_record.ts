import { match, P } from "zttp:core";
// Proves: type tests do not cover a record member (ZTS603), and a test for a kind the type lacks is unreachable (ZTS216).
type Mixed = string | { w: number };

function describe(m: Mixed): string | undefined {
    const out = match(m)
        .with(P.string, () => "text")
        .with(P.number, () => "count")
        .exhaustive();
    return out;
}

function handler(req: Request): Proof<Response, "deterministic"> {
    const value: Mixed = "s";
    return Response.json({ out: describe(value) });
}
