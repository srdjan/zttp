// Proves: a mutable top-level export is refused (ZTS057).
export let counter = 0;

function handler(req: Request): Response {
    return Response.text("ok");
}
