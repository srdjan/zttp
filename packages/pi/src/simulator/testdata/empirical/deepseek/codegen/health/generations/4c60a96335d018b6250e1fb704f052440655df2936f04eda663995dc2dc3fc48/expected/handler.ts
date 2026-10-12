structural Health<T> = Proof<T, "deterministic" | "state_isolated">;

export function handler(req: Request): Health<Response> {
  return Response.json({ ok: true });
}
