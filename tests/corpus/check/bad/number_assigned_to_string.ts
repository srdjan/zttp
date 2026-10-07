// Proves: a number expression assigned to a string binding is refused (ZTS200).
function handler(req: Request): Proof<Response, "deterministic"> {
    const s: string = 1 + 2;
    return Response.text(s);
}
