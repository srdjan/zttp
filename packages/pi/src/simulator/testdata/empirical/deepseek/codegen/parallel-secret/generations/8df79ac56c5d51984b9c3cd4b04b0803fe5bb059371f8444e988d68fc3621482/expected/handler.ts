import { env } from "zttp:env";
import { parallel } from "zttp:io";

structural Guard<T> = Proof<T, "state_isolated">;

export function handler(req: Request): Guard<Response> {
  const reads = parallel([env("APP_NAME"), env("API_SECRET")]);
  if (reads.ok === false) {
    return Response.json({ error: "service unavailable" }, 503);
  }
  const appName = reads.value[0];
  const apiSecret = reads.value[1];
  if (apiSecret === undefined) {
    return Response.json({ error: "service unavailable" }, 503);
  }
  return Response.json({ app_name: appName });
}
