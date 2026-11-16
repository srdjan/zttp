// Proves: a variable annotation that names an undeclared type is refused at the name (ZTS065).
function handler(req: Request): Proof<Response, "deterministic"> {
    const x: Missing = 1;
    return Response.text("ok");
}
