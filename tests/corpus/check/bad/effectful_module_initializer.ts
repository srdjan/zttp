// Proves: a top-level initializer that calls a helper which reads the clock is refused (ZTS630).
function stamp(): number {
    return Date.now();
}

const started: number = stamp();

function handler(req: Request): Response {
    return Response.text(String(started));
}
