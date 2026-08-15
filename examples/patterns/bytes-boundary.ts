// The octet boundary: a request body as `Bytes`, and the six kinds a decoded
// payload can be.
//
// `requestBody` is total. A request with no body is an empty `Bytes`, not an
// absence, so there is no `Result` to unwrap and no arm for "there was nothing
// there" - the length answers that question instead.
//
// Everything past that point is fallible and says so. `decodeUtf8` refuses
// invalid UTF-8 rather than substituting a replacement character, and
// `parseJsonBytes` validates UTF-8 first and then applies the JSON rules, so a
// malformed body names which of the two it failed.
//
// `kindOf` dispatches on the six type tests a `match` pattern can name -
// `boolean`, `number`, `string`, `array`, `Dict`, `Bytes` - over the `unknown`
// the parser hands back. The `default` arm is there because `unknown` is open,
// not because the six are incomplete: a closed union covered member by member
// needs no `default`, and `recursive-json-value.ts` is that case.
//
// `label` declares a trailing default. Omitting the argument selects it and the
// body sees `string`, never the omission sentinel. Only a trailing parameter
// may carry one, and only a compile-time scalar - a computed default would put
// evaluation order in front of the body.
//
// `describeOctets` is exported and this handler never calls it. It still
// declares an `Effects<...>` ceiling, because export is what the rule conditions
// on: the module's public surface owes its callers a ceiling whether or not
// this handler is one of them.

import { env } from "zttp:env";
import { bytesLength, decodeUtf8, encodeUtf8 } from "zttp:bytes";
import { parseJsonBytes } from "zttp:json";

structural Guardrails<T> = Proof<T,
    | "read_only"
    | "retry_safe"
    | "state_isolated"
    | "stateless"
    | "result_safe"
    | "optional_safe"
    | "no_credential_leakage"
    | "input_validated"
    | "pii_contained"
    | "injection_safe"
    | "canonical"
    | "cost_bounded"
>;

// The six type tests, one arm each. `Bytes` is among them, which is what makes
// an octet value dispatchable rather than opaque.
function kindOf(value: unknown): string {
  return match (value) {
    when boolean: "boolean"
    when number: "number"
    when string: "string"
    when array: "array"
    when Dict: "dict"
    when Bytes: "bytes"
    default: "other"
  };
}

// The trailing default: `label(k)` selects "payload", `label(k, "body")`
// overrides it.
function label(kind: string, prefix: string = "payload"): string {
  return `${prefix}:${kind}`;
}

// Exported, never called from this handler, and still owing a ceiling.
export function describeOctets(
  raw: Bytes,
): Proof<Effects<string, "env" | "policy_check">, "total" | "read_only" | "deterministic"> {
  const scope = env("BYTES_SCOPE");
  const kind = kindOf(raw);
  if (scope === undefined) {
    return label(kind);
  }
  return label(kind, scope);
}

function handler(
  req: Request,
): Guardrails<Effects<Response, "env" | "policy_check">> {
  const body = requestBody(req);
  const size = bytesLength(body);
  const octetKind = kindOf(body);

  const text = decodeUtf8(body);
  if (!text.ok) {
    return Response.json(
      { error: text.error.kind, size, octetKind },
      { status: 400 },
    );
  }

  const parsed = parseJsonBytes(body);
  if (!parsed.ok) {
    return Response.json(
      { error: parsed.error.kind, size, octetKind },
      { status: 400 },
    );
  }

  const scope = env("BYTES_SCOPE");
  const documentKind = kindOf(parsed.value);
  if (scope === undefined) {
    return Response.json({
      size,
      octetKind,
      documentKind,
      named: label(documentKind),
      overridden: label(documentKind, "body"),
      reEncoded: kindOf(encodeUtf8(documentKind)),
    });
  }
  return Response.json({
    size,
    octetKind,
    documentKind,
    named: label(documentKind, scope),
    overridden: label(documentKind, "body"),
    reEncoded: kindOf(encodeUtf8(documentKind)),
  });
}
