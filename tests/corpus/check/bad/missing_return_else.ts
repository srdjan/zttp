// Proves: an if without an else leaves a path with no return, which is refused (ZTS302).

structural Guardrails<T> = Proof<T, "result_safe">;

function handler(req: Request): Guardrails<Response> {
    const url = req.url;
    if (url === "/health") {
        return Response.json({ status: "ok" });
    }
    // Missing: return for non-health paths
}
