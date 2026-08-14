import { sql, sqlMany } from "zttp:sql";
import type { Spec } from "zttp:types";

sql("list_users", "SELECT id, name FROM users ORDER BY id");

function handler(req: Request): Response & Spec<"retry_safe" | "state_isolated" | "stateless" | "result_safe" | "optional_safe" | "no_secret_leakage" | "no_credential_leakage" | "input_validated" | "pii_contained" | "injection_safe" | "canonical" | "cost_bounded"> {
    const users = sqlMany("list_users");
    return Response.json({ users: users });
}
