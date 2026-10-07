// Proves: an object spread that follows an explicit key is refused (ZTS614).
function handler(req: Request): Proof<Response, "deterministic"> {
    const base = { a: 1 };
    const next = { status: "ok", ...base };
    return Response.json({ next: next });
}
