// Proves: a function and an annotated arrow written on one line keep separate signatures, so the call checks against the function's own parameter list.
structural Guardrails<T> = Proof<T, "result_safe">;

function bump(xs: number[]): number[] { return xs.map((x: number): number => x + 1); }

function handler(req: Request): Guardrails<Response> {
    const ys = bump([1, 2]);
    return Response.json({ ys: ys });
}
