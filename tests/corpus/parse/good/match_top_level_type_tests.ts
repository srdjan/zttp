// Proves: top-level type-test patterns over a closed union parse and pass every stage with no default arm.
structural Guardrails<T> = Proof<T, "result_safe">;

function handler(req: Request): Guardrails<Response> {
    const value: string | number = 1;
    const label = match (value) {
        when string: "text"
        when number: "count"
    };
    return Response.text(label);
}
