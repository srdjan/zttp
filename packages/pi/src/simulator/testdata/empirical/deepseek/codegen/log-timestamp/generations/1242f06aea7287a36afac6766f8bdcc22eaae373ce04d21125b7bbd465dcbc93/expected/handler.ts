import { logInfo } from "zttp:log";

structural LoggedResponse<T> = Proof<T, "deterministic" | "state_isolated">;

export function handler(req: Request): LoggedResponse<Response> {
  const at = Date.now();
  logInfo("served request", { at: at });
  return Response.json({ ok: true });
}
