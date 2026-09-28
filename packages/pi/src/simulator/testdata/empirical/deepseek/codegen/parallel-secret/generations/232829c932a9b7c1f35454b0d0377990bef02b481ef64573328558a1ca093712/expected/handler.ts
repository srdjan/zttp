import { env } from "zttp:env";
import { parallel } from "zttp:io";

// Both env vars are read concurrently. The secret is only ever probed for
// presence; the response body is built from a value that never passed
// through the parallel result object.
structural AppProof<T> = Proof<T, "state_isolated" | "no_secret_leakage" | "canonical">;

export function handler(req: Request): AppProof<Response> {
  const reads = parallel([
    () => env("APP_NAME"),
    () => env("API_SECRET")
  ]);
  const apiSecret = reads.results[1];
  if (apiSecret === undefined) {
    return Response.json({ error: "API_SECRET is not configured" }, { status: 503 });
  }
  const appName = env("APP_NAME");
  if (appName === undefined) {
    return Response.json({ error: "APP_NAME is not configured" }, { status: 503 });
  }
  return Response.json({ appName: appName });
}
