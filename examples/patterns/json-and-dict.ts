// The JSON boundary and the keyed data it decodes into.
//
// `parseJson` returns a `Result`, so a malformed document is a value the
// handler decides about rather than a trap. Every failure names itself: an
// `invalid-syntax` carries the offset, a `duplicate-key` carries the key, and
// the two limits carry the limit they hit. A repeated key is refused rather
// than last-wins, so two documents that differ only in a repeat can never
// decode to the same value.
//
// Object nodes decode to `Dict<string, JsonValue>`, which iterates in wire
// order and answers key equality with SameValueZero. `null` is data here: it
// survives the round trip instead of becoming `undefined`.
//
// `isDict` is the intrinsic guard that turns the parsed `unknown` into
// something the collection operations accept - the same guard `when Dict:`
// lowers to inside a `match`.

import type { Spec } from "zttp:types";
import { parseJson, stringifyJson } from "zttp:json";
import { dictGet, dictEntries } from "zttp:collections";

structural Guardrails = Spec<
    | "deterministic"
    | "read_only"
    | "retry_safe"
    | "idempotent"
    | "state_isolated"
    | "stateless"
    | "no_secret_leakage"
    | "no_credential_leakage"
    | "input_validated"
    | "pii_contained"
    | "injection_safe"
    | "canonical"
    | "cost_bounded"
>;

function handler(req: Request): Response & Guardrails {
  const parsed = parseJson(
    "{\"name\":\"ada\",\"tags\":[1,null,true],\"ok\":true}",
  );
  if (!parsed.ok) {
    return Response.json({ error: parsed.error.kind }, { status: 400 });
  }

  const document = parsed.value;
  if (!isDict(document)) {
    return Response.json({ error: "not-an-object" }, { status: 400 });
  }

  const duplicate = parseJson("{\"a\":1,\"a\":2}");
  const malformed = parseJson("{oops}");
  const encoded = stringifyJson(document);
  if (!encoded.ok) {
    return Response.json({ error: encoded.error.kind }, { status: 500 });
  }

  return Response.json({
    name: dictGet(document, "name"),
    entries: dictEntries(document),
    roundTrip: encoded.value,
    duplicateKind: duplicate.error.kind,
    duplicateKey: duplicate.error.key,
    malformedKind: malformed.error.kind,
    malformedOffset: malformed.error.offset,
  });
}
