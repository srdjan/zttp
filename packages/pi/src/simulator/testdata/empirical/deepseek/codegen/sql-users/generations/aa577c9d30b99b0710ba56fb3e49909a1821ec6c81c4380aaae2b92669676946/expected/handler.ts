import { sql, sqlMany } from "zttp:sql";

structural UsersProof<T> = Proof<T, "state_isolated">;

sql("listUsers", "SELECT id, name FROM users");

export function handler(req: Request): UsersProof<Response> {
  const users = sqlMany("listUsers");
  return Response.json({ users: users });
}
