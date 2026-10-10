import { sql, sqlMany } from "zttp:sql";

structural Guard<T> = Proof<T, "state_isolated" | "canonical">;

sql("listUsers", "SELECT id, name FROM users");

export function handler(req: Request): Guard<Response> {
  const users: object[] = sqlMany("listUsers");
  return Response.json({ users: users });
}
