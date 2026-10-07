// Proves: an authorization header labelled credential that reaches a response body is refused (ZTS401).
function handler(req: Request): Proof<Response, "deterministic"> {
    const auth = req.headers.authorization ?? "";
    return Response.json({ auth: auth });
}
