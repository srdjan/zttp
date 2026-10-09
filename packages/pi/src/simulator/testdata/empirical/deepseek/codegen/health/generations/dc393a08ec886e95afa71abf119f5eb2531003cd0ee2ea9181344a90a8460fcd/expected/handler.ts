export function handler(req: Request): Proof<Response, "pure" | "read_only" | "retry_safe" | "state_isolated" | "injection_safe"> {
  return Response.json({ ok: true });
}
