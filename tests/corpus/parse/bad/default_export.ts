// Proves: a default export is refused, exports are statically named (ZTS056).
export default function handler(req: Request): Response {
    return Response.text("ok");
}
