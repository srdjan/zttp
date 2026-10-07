// Proves: a handler that assigns a module-scope variable is refused (ZTS310).
let count = 0;

function handler(req: Request): Proof<Response, "deterministic"> {
    count = count + 1;
    return Response.json({ count: count });
}
