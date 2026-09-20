import { cacheGet } from "zttp:cache";

structural Guard<T> = Proof<T,
  | "state_isolated"
  | "retry_safe"
  | "optional_safe"
  | "input_validated"
  | "pii_contained"
  | "injection_safe"
  | "canonical"
  | "cost_bounded"
>;

export function handler(req: Request): Guard<Response> {
  const hits: string = cacheGet("counters", "hits") ?? "0";
  return Response.json({ hits: hits });
}
