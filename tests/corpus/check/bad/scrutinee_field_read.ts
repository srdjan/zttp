// Proves: a match arm that reads a field off the scrutinee instead of binding it is refused (ZTS626).
structural Msg = { kind: string, text: string };

function handler(req: Request): Proof<Response, "deterministic"> {
    const msg: Msg = { kind: "echo", text: "hi" };
    const out = match (msg) {
        when { kind: "echo" }: msg.text
        default: "none"
    };
    return Response.json({ out: out });
}
