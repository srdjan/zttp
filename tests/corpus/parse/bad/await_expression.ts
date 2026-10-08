// Proves: an `await` expression is refused with the synchronous-handler repair (ZTS026).
function handler(req: Request): Response {
    const a = await 1;
    return Response.text(String(a));
}
