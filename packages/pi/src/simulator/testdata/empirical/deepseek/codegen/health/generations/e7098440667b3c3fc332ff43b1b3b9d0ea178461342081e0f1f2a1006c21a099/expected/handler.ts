structural HealthResponse<T> = Proof<T, "deterministic" | "state_isolated">;

export function handler(req: Request): HealthResponse<Response> {
  return Response.json({ ok: true });
}
