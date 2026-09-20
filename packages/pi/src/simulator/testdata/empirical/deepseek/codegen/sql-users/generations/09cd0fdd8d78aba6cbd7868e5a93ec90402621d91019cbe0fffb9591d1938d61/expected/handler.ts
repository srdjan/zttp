import { sql, sqlMany } from "zttp:sql";

sql("listUsers", "SELECT id, name FROM users ORDER BY id");

export function handler(req: Request): Proof<Response, "state_isolated"> {
  const users = sqlMany("listUsers");
  return Response.json(users);
}
