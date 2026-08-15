// Should pass: all paths return

structural Guardrails<T> = Proof<T, "result_safe">;

function handler(req: Request): Guardrails<Response> {
    const url = req.url;
    if (url === "/health") {
        return Response.json({ status: "ok" });
    }
    return Response.json({ error: "not found" }, { status: 404 });
}
