// Proves: a top-level statement other than a registration call with literal arguments is refused (ZTS074).
function warm(): number {
    return 1;
}

warm();

function handler(req: Request): Response {
    return Response.text(String(warm()));
}
