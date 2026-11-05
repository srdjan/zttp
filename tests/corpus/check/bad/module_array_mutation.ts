// Proves: a handler that calls a mutating array method on a module-scope array is refused (ZTS310).
const seen: number[] = [];

function handler(req: Request): Proof<Response, "deterministic"> {
    seen.push(1);
    return Response.text(String(seen.length));
}
