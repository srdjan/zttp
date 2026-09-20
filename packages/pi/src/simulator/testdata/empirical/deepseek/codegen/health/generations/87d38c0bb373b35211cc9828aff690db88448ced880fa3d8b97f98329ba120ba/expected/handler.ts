structural HealthProof<T> = Proof<T, "deterministic" | "state_isolated" | "canonical">;

export function handler(req: Request): HealthProof<Response> {
  if (req.method !== "GET" || req.path !== "/health") {
    return Response.json({ error: "not found" }, { status: 404 });
  }
  return Response.json({ ok: true });
}
