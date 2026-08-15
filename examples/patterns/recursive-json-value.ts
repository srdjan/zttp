// Recursive application data: one alias, one match, no default arm.
//
// `JsonValue` names itself through an array constructor, which is what makes
// the recursion contractive: every cycle passes through a record, a tuple, or
// an array, so the type describes finite values and the checker unfolds it
// without expanding a cycle. A cycle through only union edges - `type U =
// number | U` - is refused instead.
//
// `null` is data here, not an absence sentinel. It is admitted because the
// declared type names it, and `??` and `?.` are refused on a value of this
// type precisely because they would swallow it.
//
// The `null` literal pattern and the four type-test patterns cover the five
// value kinds exactly, so the match is exhaustive with no `default` - which a
// closed union is required to do without. The `Dict` arm of the spec's version
// arrives with `Dict` itself.
//
// The function below is not recursive. Walking a `JsonValue` to its depth is
// the natural recursive fold, and capsule discharge does not admit a recursive
// helper yet, so a handler that declares a `Spec` cannot call one. The
// recursive fold is pinned as a type-checker test instead.


structural JsonValue =
    | null
    | boolean
    | number
    | string
    | readonly JsonValue[];

structural Guardrails<T> = Proof<T,
    | "deterministic"
    | "read_only"
    | "retry_safe"
    | "idempotent"
    | "state_isolated"
    | "injection_safe"
    | "no_secret_leakage"
    | "input_validated"
>;

function kindOf(value: JsonValue): string {
  return match (value) {
    when null: "null"
    when boolean: "boolean"
    when number: "number"
    when string: "string"
    when array: "array"
  };
}

function handler(req: Request): Guardrails<Response> {
  const document: JsonValue = [1, "two", true, null, [3]];
  const kinds = document.map(kindOf);
  return Response.json({ outer: kindOf(document), kinds });
}
