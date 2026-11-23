// Proves that brace match cannot execute after the source cutover.
export function handler(req: Request): Response {
    return match (req.method) {
        when "GET": Response.text("get")
        default: Response.text("other")
    };
}
