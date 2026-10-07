// Proves: a boolean compared against a boolean literal is refused (ZTS620).
function handler(req: Request): Proof<Response, "deterministic"> {
    const ready = true;
    if (ready === true) { return Response.json({ ready: 9 }); }
    return Response.json({ ready: 0 });
}
