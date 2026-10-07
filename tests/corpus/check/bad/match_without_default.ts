// Proves: a match over an open type with no default arm is refused as non-exhaustive.
structural Guardrails<T> = Proof<T, "result_safe">;

function handler(req: Request): Guardrails<Response> {
    return match (req.method) {
        when "GET": Response.json({ ok: true })
    };
}
