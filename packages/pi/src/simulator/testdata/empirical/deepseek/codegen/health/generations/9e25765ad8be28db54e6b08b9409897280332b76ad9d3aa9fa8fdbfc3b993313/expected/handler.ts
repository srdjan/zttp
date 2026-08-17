structural Guard<T> = Proof<T, "deterministic" | "state_isolated">;

export function handler(req: Request): Guard<Response> {
  if (req.method === "GET" && req.path === "/health") {
    return Response.json({ ok: true });
  }
  return Response.json({ error: "not found" }, { status: 404 });
}
