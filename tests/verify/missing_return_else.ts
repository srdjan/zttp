// Should fail: if-without-else doesn't guarantee a return

structural Guardrails<T> = Proof<T, "result_safe">;

function handler(req: Request): Guardrails<Response> {
    const url = req.url;
    if (url === "/health") {
        return Response.json({ status: "ok" });
    }
    // Missing: return for non-health paths
}
