import { sql, sqlMany } from "zttp:sql";

sql("listUsers", "SELECT id, name FROM users");

structural Guard<T> = Proof<T, "state_isolated">;

export function handler(req: Request): Guard<Response> {
  const users = sqlMany("listUsers");
  return Response.json(users);
}
