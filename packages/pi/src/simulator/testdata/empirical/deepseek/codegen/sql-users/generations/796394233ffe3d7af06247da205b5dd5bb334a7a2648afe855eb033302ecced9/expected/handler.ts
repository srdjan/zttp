import { sql, sqlMany } from "zttp:sql";

sql("listUsers", "SELECT id, name FROM users");

structural UsersProof<T> = Proof<T,
  | "retry_safe"
  | "state_isolated"
  | "no_secret_leakage"
  | "no_credential_leakage"
  | "input_validated"
  | "pii_contained"
  | "injection_safe"
>;

export function handler(req: Request): UsersProof<Response> {
  const users = sqlMany("listUsers");
  return Response.json({ users: users });
}
