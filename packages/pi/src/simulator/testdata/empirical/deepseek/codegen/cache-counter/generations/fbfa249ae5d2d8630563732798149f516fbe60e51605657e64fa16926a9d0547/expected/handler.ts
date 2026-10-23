import { cacheGet } from "zttp:cache";

export function handler(req: Request): Proof<Response,
  | "state_isolated"
  | "optional_safe"
  | "canonical"
> {
  const hits: string = cacheGet("counters", "hits") ?? "0";
  return Response.json({ hits: hits });
}
