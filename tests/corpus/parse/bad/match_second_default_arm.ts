// Proves: a second `default` arm in one match is refused at parse time.
function handler(req: Request): Response {
    const label = match (req.method) {
        when "GET": "read"
        default: "first"
        default: "second"
    };
    return Response.text(label);
}
