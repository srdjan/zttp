import { apiToken } from "./lib/settings.ts";

structural PublicStatus<T> = Proof<T, "read_only">;

export function handler(req: Request): PublicStatus<Response> {
  if (apiToken() === undefined) {
    return Response.json({ error: "settings unavailable" }, { status: 503 });
  }

  return Response.json({ name: "unnamed" });
}
