import { fetch } from "zttp:fetch";

structural Guard<T> = Proof<T, "state_isolated">;

export function handler(req: Request): Guard<Response> {
  const upstream = fetch("https://api.example.com/v1/status", {
    method: "GET",
    headers: { accept: "application/json" }
  });
  if (!upstream.ok) {
    return Response.json({ error: "upstream status unavailable" }, { status: 502 });
  }
  return Response.json(upstream.json());
}
