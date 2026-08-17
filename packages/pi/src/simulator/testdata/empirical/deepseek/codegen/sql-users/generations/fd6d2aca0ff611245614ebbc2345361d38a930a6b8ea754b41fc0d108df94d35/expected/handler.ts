import { sql, sqlMany } from "zttp:sql";

sql("listUsers", "SELECT id, name FROM users");

structural SqlProof<T> = Proof<T, "state_isolated">;

export function handler(req: Request): SqlProof<Response> {
  const users = sqlMany("listUsers");
  return Response.json({ users: users });
}
