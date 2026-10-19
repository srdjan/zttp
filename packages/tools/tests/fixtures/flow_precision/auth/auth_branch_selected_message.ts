import { env } from "zttp:env";
import { timingSafeEqual } from "zttp:auth";

export function handler(req: Request): Proof<Response, "no_secret_leakage" | "no_credential_leakage"> {
  const expected = env("ADMIN_TOKEN") ?? "";
  const presented = req.headers.get("x-admin-token") ?? "";
  let message: string = "denied";
  let status: number = 403;
  if (expected.length > 0 && timingSafeEqual(presented, expected)) {
    message = "welcome";
    status = 200;
  }
  return Response.json({ message: message }, { status: status });
}
