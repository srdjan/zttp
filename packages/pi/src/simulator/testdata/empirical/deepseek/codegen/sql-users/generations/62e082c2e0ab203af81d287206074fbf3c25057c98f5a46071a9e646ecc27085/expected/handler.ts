import { sql, sqlMany } from "zttp:sql";

structural User = { id: number, name: string };

sql("listUsers", "SELECT id, name FROM users");

export function handler(req: Request): Proof<Response, "state_isolated"> {
  const rows = sqlMany("listUsers");
  const users: User[] = rows.map((row: object): User => ({ id: row.id, name: row.name }));
  return Response.json({ users: users });
}
