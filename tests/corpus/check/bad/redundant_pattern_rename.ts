// Proves: a match record pattern that renames a field to its own name is refused (ZTS625).
structural Msg = { kind: string, text: string };

function handler(req: Request): Proof<Response, "deterministic"> {
    const msg: Msg = { kind: "echo", text: "hi" };
    const out = match (msg) {
        when { kind: "echo", text: text }: text
        default: "none"
    };
    return Response.json({ out: out });
}
