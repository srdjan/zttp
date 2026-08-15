// Should warn: unreachable code after return

structural Guardrails<T> = Proof<T, "result_safe">;

function handler(req: Request): Guardrails<Response> {
    return Response.json({ ok: true });
    const x = 42;
}
