// Proves: a `switch` statement is refused at parse time in favor of `match`.
function handler(req: Request): Response {
    switch (req.method) {
        case "GET":
            return Response.text("read");
        default:
            return Response.text("other");
    }
}
