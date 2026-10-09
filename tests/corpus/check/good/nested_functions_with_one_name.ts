// Proves: nested functions that share a name keep their own signatures, whichever one is declared first.
structural Guardrails<T> = Proof<T, "result_safe">;

function narrow(): number {
    function inner(x: number): number { return x; }
    return inner(1);
}

function wide(): number {
    function inner(x: number, y: number): number { return x + y; }
    return inner(1, 2);
}

function wideFirst(): number {
    function twin(x: number, y: number): number { return x + y; }
    return twin(1, 2);
}

function narrowSecond(): number {
    function twin(x: number): number { return x; }
    return twin(1);
}

function handler(req: Request): Guardrails<Response> {
    return Response.json({ a: narrow(), b: wide(), c: wideFirst(), d: narrowSecond() });
}
