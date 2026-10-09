import { cacheGet } from "zttp:cache";

structural HitsProof<T> = Proof<T,
  | "canonical"
  | "cost_bounded"
  | "injection_safe"
  | "input_validated"
>;

export function handler(req: Request): HitsProof<Response> {
  const stored = cacheGet("counters", "hits");
  const hits: number = parseInt(stored ?? "0", 10);
  return Response.json({ hits: hits });
}
