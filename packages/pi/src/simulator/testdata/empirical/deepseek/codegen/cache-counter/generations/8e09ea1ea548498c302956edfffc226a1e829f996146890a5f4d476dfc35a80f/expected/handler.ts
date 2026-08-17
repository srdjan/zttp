import { cacheGet } from "zttp:cache";

structural CacheProof<T> = Proof<T,
  | "state_isolated"
  | "optional_safe"
  | "canonical"
>;

export function handler(req: Request): CacheProof<Response> {
  const hits: string = cacheGet("counters", "hits") ?? "0";
  return Response.json({ hits: hits });
}
