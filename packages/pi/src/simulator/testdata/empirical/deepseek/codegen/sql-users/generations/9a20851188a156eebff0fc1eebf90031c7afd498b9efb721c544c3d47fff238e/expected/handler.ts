import { sql, sqlMany } from "zttp:sql";

sql("selectAllUsers", "SELECT id, name FROM users");

structural Guard<T> = Proof<T, "state_isolated">;

export function handler(req: Request): Guard<Response> {
  const users = sqlMany("selectAllUsers");
  return Response.json({ users: users });
}
