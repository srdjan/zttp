import { env } from "zttp:env";
import { parallel } from "zttp:io";

structural AppNameSlot = { appName: string };

export function handler(
  req: Request,
): Proof<Response, "no_secret_leakage" | "state_isolated"> {
  const slot: AppNameSlot = { appName: "" };
  const reads = parallel([
    () => {
      slot.appName = env("APP_NAME") ?? "";
    },
    (): boolean => env("API_SECRET") === undefined,
  ]);
  const secretMissing: boolean = reads[1];
  if (secretMissing) {
    return Response.json({ error: "service unavailable" }, { status: 503 });
  }
  return Response.json({ appName: slot.appName });
}
