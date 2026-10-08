// Proves: a nominal type name used as a constructor call is refused (ZTS214).
nominal UserId = string;

function handler(req: Request): Proof<Response, "deterministic"> {
    const id = UserId("u-1");
    return Response.text(id);
}
