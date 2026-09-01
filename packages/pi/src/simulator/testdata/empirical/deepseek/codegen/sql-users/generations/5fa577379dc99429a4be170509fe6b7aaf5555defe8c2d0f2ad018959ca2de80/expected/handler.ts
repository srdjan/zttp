import { sql, sqlMany } from "zttp:sql";

sql("listUsers", "SELECT id, name FROM users");

structural Guard<T> = Proof<T,
  | "state_isolated"
  | "result_safe"
  | "optional_safe"
  | "no_secret_leakage"
  | "no_credential_leakage"
  | "input_validated"
  | "pii_contained"
  | "injection_safe"
  | "canonical"
>;

export function handler(req: Request): Guard<Response> {
  const users = sqlMany("listUsers");
  return Response.json(users);
}
