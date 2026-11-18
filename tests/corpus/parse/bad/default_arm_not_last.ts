// Proves: a `default` arm that is followed by another arm is refused at parse time (ZTS062).
function handler(req: Request): Response {
    const label = match (req.method) {
        when "GET": "a"
        default: "b"
        when "POST": "c"
    };
    return Response.text(label);
}
