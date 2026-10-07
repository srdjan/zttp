// Proves: the `distinct type` spelling is refused in favor of `nominal` (ZTS051).
distinct type UserId = string;

function handler(req: Request): Response {
    return Response.text("ok");
}
