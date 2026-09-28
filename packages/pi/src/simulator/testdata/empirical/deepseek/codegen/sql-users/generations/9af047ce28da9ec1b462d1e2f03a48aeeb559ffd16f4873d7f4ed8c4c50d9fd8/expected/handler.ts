import { sql, sqlMany } from "zttp:sql";

const listUsers = sql("listUsers", "SELECT id, name FROM users");

export function handler(req: Request): Proof<Response, "retry_safe" | "state_isolated" | "stateless" | "result_safe" | "optional_safe" | "input_validated" | "pii_contained" | "injection_safe" | "canonical" | "cost_bounded"> {
  const users = sqlMany("listUsers");
  return Response.json({ users: users });
}
