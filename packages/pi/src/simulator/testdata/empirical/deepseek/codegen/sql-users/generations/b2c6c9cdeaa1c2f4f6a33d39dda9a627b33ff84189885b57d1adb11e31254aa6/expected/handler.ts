import { sql, sqlMany } from "zttp:sql";

sql("allUsers", "SELECT id, name FROM users");

structural UsersGuard<T> = Proof<T, "state_isolated">;

export function handler(req: Request): UsersGuard<Response> {
  const users = sqlMany("allUsers");
  return Response.json({ users: users });
}
