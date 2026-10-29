structural HealthOk<T> = Proof<T, "deterministic" | "state_isolated">;

export function handler(req: Request): HealthOk<Response> {
  return Response.json({ ok: true });
}
