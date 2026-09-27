import { sql, sqlMany } from "zttp:sql";

sql("listUsers", "SELECT id, name FROM users");

export function handler(req: Request): Proof<Response, "state_isolated"> {
  const rows = sqlMany("listUsers");
  return Response.json({ users: rows });
}
