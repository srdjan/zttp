structural Guard<T> = Proof<T, "deterministic">;

export function handler(req: Request): Guard<Response> {
  return Response.json({ ok: true });
}
