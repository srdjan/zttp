// Proves: an annotation naming an undeclared type is refused (reported today as an assignability failure, ZTS200).
function handler(req: Request): Proof<Response, "deterministic"> {
    const x: Missing = 1;
    return Response.text("ok");
}
