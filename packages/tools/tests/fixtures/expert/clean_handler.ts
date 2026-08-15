function handler(req: Request): Proof<Response, "deterministic"> {
  return Response.json({ ok: true });
}
