import { sql, sqlMany } from "zttp:sql";

sql("listUsers", "SELECT id, name FROM users ORDER BY id");

structural UsersProof<T> = Proof<T,
  | "state_isolated"
  | "result_safe"
  | "optional_safe"
  | "no_secret_leakage"
  | "no_credential_leakage"
  | "input_validated"
  | "pii_contained"
  | "injection_safe"
  | "canonical"
  | "cost_bounded"
>;

export function handler(req: Request): UsersProof<Response> {
  const users = sqlMany("listUsers");
  return Response.json(users);
}
