import { cacheGet } from "zttp:cache";

structural HandlerProof<T> = Proof<T, "state_isolated">;

export function handler(req: Request): HandlerProof<Response> {
  const raw = cacheGet("counters", "hits");
  const hits: number = parseInt(raw ?? "0", 10);
  return Response.json({ hits: hits });
}
