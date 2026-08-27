structural Guard<T> = Proof<T, "state_isolated">;

export function handler(req: Request): Guard<Response> {
  return Response.json({ ok: true });
}
