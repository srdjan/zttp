// Proves: a match over an open type with no default arm is refused as non-exhaustive (ZTS603), and the help names the missing case.

structural Guardrails<T> = Proof<T, "result_safe">;

function handler(req: Request): Guardrails<Response> {
    const label = match (req.method) {
        when "GET": "read"
    };
    return Response.json({ label: label });
}
