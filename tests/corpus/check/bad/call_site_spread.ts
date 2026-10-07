// Proves: a spread argument at a call site is refused (ZTS616).
function send(a: number): number {
    return a + a;
}

function handler(req: Request): Proof<Response, "deterministic"> {
    const args = [1];
    const sent = send(...args);
    return Response.json({ sent: sent });
}
