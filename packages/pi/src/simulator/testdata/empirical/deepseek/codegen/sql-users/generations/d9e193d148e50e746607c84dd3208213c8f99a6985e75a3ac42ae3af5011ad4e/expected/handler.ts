import { sql, sqlMany } from "zttp:sql";

structural Guard<T> = Proof<T, "state_isolated">;

sql("allUsers", "SELECT id, name FROM users");

export function handler(req: Request): Guard<Response> {
  const users = sqlMany("allUsers");
  return Response.json({ users: users });
}
