import { env } from "zttp:env";
import { verifyWebhookSignature } from "zttp:auth";
import { logInfo } from "zttp:log";

export function handler(req: Request): Proof<Response, "no_secret_leakage" | "no_credential_leakage"> {
  const secret = env("WEBHOOK_SECRET");
  if (secret === undefined) {
    return Response.json({ error: "server misconfigured" }, { status: 500 });
  }
  const signature = req.headers.get("x-signature");
  if (signature === undefined) {
    return Response.json({ error: "missing signature" }, { status: 401 });
  }
  const body: string = req.body ?? "";
  if (!verifyWebhookSignature(body, signature, secret)) {
    return Response.json({ error: "bad signature" }, { status: 401 });
  }
  logInfo("webhook accepted", { size: body.length });
  return Response.json({ received: true });
}
