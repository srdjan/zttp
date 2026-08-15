import { schemaCompile, validateJson } from "zttp:validate";
import { sql, sqlExec, sqlMany } from "zttp:sql";

// A stateful (zttp:sql) handler cannot hold the default profile's
// pure/stateless/idempotent/retry_safe, so it declares the narrow set it does
// hold. Without a Spec the compiler must prove the full default profile (ZTS500).
//
// `deterministic` is not on the list either. The GET path returns the rows
// `sqlMany` reads, and a later run of the same request answers with whatever
// the last insert left in the table. This example declared it until the flow
// checker learned that a read from mutable module state varies the same way a
// clock read does - `zttp:sql` declares no clock, so nothing had caught it.
structural CrudGuarantees<T> = Proof<T,
    | "state_isolated"
    | "fault_covered"
    | "result_safe"
    | "optional_safe"
    | "no_secret_leakage"
    | "no_credential_leakage"
    | "input_validated"
    | "pii_contained"
    | "injection_safe"
    | "canonical"
>;

schemaCompile(
  "todo.create",
  JSON.stringify({
    type: "object",
    required: ["title"],
    properties: { title: { type: "string", minLength: 1, maxLength: 120 } },
  }),
);

sql("listTodos", "SELECT id, title, done FROM todos ORDER BY id ASC");
sql("createTodo", "INSERT INTO todos (title, done) VALUES (:title, 0)");

function handler(req: Request): CrudGuarantees<Response> {
  if (req.method === "GET") {
    return Response.json({ items: sqlMany("listTodos") });
  }

  const parsed = validateJson("todo.create", req.body ?? "");
  if (!parsed.ok) {
    return Response.json({ errors: parsed.errors }, { status: 400 });
  }

  return Response.json(sqlExec("createTodo", { title: parsed.value.title }), {
    status: 201,
  });
}
