import { sql, sqlMany } from "zttp:sql";

sql("users.list", "SELECT id, name FROM users");

structural UsersProof<T> = Proof<T,
  | "state_isolated"
  | "result_safe"
  | "optional_safe"
  | "canonical"
  | "cost_bounded"
>;

export function handler(req: Request): UsersProof<Response> {
  const users: object[] = sqlMany("users.list");
  return Response.json({ users: users });
}
