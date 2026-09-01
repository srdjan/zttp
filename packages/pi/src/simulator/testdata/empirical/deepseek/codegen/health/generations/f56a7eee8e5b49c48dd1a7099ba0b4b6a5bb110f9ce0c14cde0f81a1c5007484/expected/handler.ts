export function handler(req: Request): Proof<Response, "deterministic" | "state_isolated"> {
  if (req.method !== "GET" || req.path !== "/health") {
    return Response.json({ error: "not found" }, { status: 404 });
  }
  return Response.json({ ok: true });
}
