import { cacheGet } from "zttp:cache";

structural CounterProof<T> = Proof<T, "state_isolated" | "optional_safe">;

export function handler(req: Request): CounterProof<Response> {
  const hits: string = cacheGet("counters", "hits") ?? "0";
  return Response.json({ hits: hits });
}
