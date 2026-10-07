// Proves: a string literal assigned to a number binding is refused (ZTS200).
function handler(req: Request): Proof<Response, "deterministic"> {
    const n: number = "text";
    return Response.text(String(n));
}
