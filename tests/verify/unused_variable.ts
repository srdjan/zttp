// Should warn: declared variable is never used

structural Guardrails<T> = Proof<T, "result_safe">;

function handler(req: Request): Guardrails<Response> {
    const unused = "hello";
    return Response.json({ ok: true });
}
