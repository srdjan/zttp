// Proves: a declared variable that is never read is reported as a warning (ZTS305).

structural Guardrails<T> = Proof<T, "result_safe">;

function handler(req: Request): Guardrails<Response> {
    const unused = "hello";
    return Response.json({ ok: true });
}
