import { sql, sqlMany } from "zttp:sql";

sql("list_users", "SELECT id, name FROM users ORDER BY id");

structural SqlRead = Spec<
    | "retry_safe"
    | "state_isolated"
    | "injection_safe"
>;

function handler(req: Request): Response & SqlRead {
    const users = sqlMany("list_users");
    return Response.json(users);
}
