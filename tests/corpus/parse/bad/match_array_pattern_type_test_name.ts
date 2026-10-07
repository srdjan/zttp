// Proves: a type-test name used as an element inside an array pattern is refused (ZTS001).
function handler(req: Request): Response {
    const input = ["text"];
    const label = match (input) {
        when [string]: "array"
        default: "other"
    };
    return Response.text(label);
}
