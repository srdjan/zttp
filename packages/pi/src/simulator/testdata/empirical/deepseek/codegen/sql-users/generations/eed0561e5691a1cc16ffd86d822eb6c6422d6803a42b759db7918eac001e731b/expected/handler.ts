import { sql, sqlMany } from "zttp:sql";

sql("allUsers", "SELECT id, name FROM users");

export function handler(req: Request): Proof<Response, "state_isolated" | "canonical"> {
  const users = sqlMany("allUsers");
  return Response.json({ users: users });
}
