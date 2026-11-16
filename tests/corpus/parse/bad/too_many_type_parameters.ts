// Proves: a generic declaration with nine type parameters is refused at the ninth with ZTS028.
function pick<A, B, C, D, E, F, G, H, I>(a: A): A {
    return a;
}
function handler(req: Request): Response {
    return Response.text("ok");
}
