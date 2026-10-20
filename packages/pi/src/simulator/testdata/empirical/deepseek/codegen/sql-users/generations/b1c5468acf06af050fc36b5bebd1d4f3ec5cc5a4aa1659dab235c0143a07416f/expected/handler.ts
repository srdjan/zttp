import { sql, sqlMany } from "zttp:sql";

structural Guard<T> = Proof<T, "state_isolated">;

sql("select_users", "SELECT id, name FROM users");

export function handler(req: Request): Guard<Response> {
  const users = sqlMany("select_users");
  return Response.json({ users: users });
}
