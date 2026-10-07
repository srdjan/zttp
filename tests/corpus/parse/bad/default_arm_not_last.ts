// Proves: a `default` arm that is followed by another arm is refused at parse time (ZTS062).
function handler(req: Request): Response {
    const label = match (1) {
        when 1: "a"
        default: "b"
        when 2: "c"
    };
    return Response.text(label);
}
