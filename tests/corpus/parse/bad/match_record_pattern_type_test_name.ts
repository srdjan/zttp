// Proves: a type-test name used as a field binding inside a record pattern is refused (ZTS001).
function handler(req: Request): Response {
    const input = { v: "text" };
    const label = match (input) {
        when { v: string }: "record"
        default: "other"
    };
    return Response.text(label);
}
