// Proves: a handler with a narrow Proof capsule and no diagnostics runs every stage.
structural Guardrails<T> = Proof<T, "result_safe">;

function handler(req: Request): Guardrails<Response> {
    return Response.json({ ok: true });
}
