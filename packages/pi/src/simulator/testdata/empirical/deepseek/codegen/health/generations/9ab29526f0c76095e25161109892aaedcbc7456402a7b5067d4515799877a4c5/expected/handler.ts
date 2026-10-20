export function handler(req: Request): Proof<Response, "deterministic" | "state_isolated"> {
  return Response.json({ ok: true });
}
