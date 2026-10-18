import { fetch } from "zttp:fetch";

export function handler(req: Request): Proof<Response,
  | "deterministic"
  | "state_isolated"
  | "fault_covered"
  | "result_safe"
  | "optional_safe"
  | "canonical"
  | "cost_bounded"
> {
  const upstream = fetch("https://api.example.com/v1/status", {
    method: "GET",
    headers: { "accept": "application/json" },
    maxResponseBytes: 65536
  });
  if (!upstream.ok) {
    return Response.json({ error: "status service unavailable" }, { status: 502 });
  }
  return Response.json(upstream.json());
}
