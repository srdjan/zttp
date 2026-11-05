// Proves: a field write on an element that a module array holds is a shared-state write (ZTS310).
structural Row = { n: number };
const rows: Row[] = [{ n: 0 }];

function handler(req: Request): Proof<Response, "deterministic"> {
    const r = rows[0];
    if (r !== undefined) {
        r.n = r.n + 1;
    }
    return Response.text("ok");
}
