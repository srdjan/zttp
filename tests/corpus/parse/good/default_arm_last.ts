// Proves: a `default` arm in last position parses and passes every stage.
structural Guardrails<T> = Proof<T, "result_safe">;

function handler(req: Request): Guardrails<Response> {
    const label = match (req.method) {
        when "GET": "read"
        when "POST": "write"
        default: "other"
    };
    return Response.text(label);
}
