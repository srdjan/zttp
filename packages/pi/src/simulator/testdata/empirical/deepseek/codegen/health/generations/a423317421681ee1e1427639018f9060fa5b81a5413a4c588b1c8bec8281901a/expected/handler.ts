structural HealthProof<T> = Proof<T, "deterministic" | "state_isolated">;

export function handler(req: Request): HealthProof<Response> {
  return Response.json({ ok: true });
}
