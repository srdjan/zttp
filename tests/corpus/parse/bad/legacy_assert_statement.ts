// Proves that only an imported assertion call can execute.
export function handler(req: Request): Response {
    assert req.method === "GET";
    return Response.text("get");
}
