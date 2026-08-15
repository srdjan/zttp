// Should fail: match without default arm

structural Guardrails<T> = Proof<T, "result_safe">;

function handler(req: Request): Guardrails<Response> {
    return match (req.method) {
        when "GET": Response.json({ ok: true })
    };
}
