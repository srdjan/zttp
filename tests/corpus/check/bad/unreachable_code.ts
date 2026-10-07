// Proves: statements after an unconditional return are reported as warnings (ZTS304).

structural Guardrails<T> = Proof<T, "result_safe">;

function handler(req: Request): Guardrails<Response> {
    return Response.json({ ok: true });
    const x = 42;
}
