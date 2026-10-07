// Proves: a match with a record pattern, a bound field and a default arm passes every stage.
structural Msg = { kind: string, text: string };

function handler(req: Request): Proof<Response, "deterministic"> {
    const msg: Msg = { kind: "echo", text: "hi" };
    const out = match (msg) {
        when { kind: "echo", text }: text
        default: "none"
    };
    return Response.json({ out: out });
}
