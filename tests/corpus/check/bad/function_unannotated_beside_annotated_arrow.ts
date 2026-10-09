// Proves: an unannotated function is refused even when an annotated arrow shares its line, because the arrow's annotations are not the function's.
structural Guardrails<T> = Proof<T, "result_safe">;

function plain(x) { return [1].map((y: number): number => y); }

function handler(req: Request): Guardrails<Response> {
    return Response.json({ a: plain(1) });
}
