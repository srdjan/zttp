---
title: Separate wire compatibility from owned domain projection
date: 2026-08-05
category: architecture-patterns
module: packages/zts contract JSON decoding
problem_type: architecture_pattern
component: tooling
severity: high
applies_when:
  - "Replacing a handwritten decoder for a stable or security-sensitive wire format"
  - "A standard typed parser's defaults differ from established duplicate, null, overflow, or unknown-field behavior"
  - "Decoded values must outlive the parser's scratch arena or input buffer"
  - "Wire metadata influences authorization, verification, hashing, or canonical serialization"
tags:
  - "typed-wire-dto"
  - "std-json"
  - "pure-projection"
  - "compatibility-boundary"
  - "owned-domain-values"
  - "duplicate-fields"
  - "allocation-failure"
  - "sandbox-verification"
---

# Separate wire compatibility from owned domain projection

## Context

Replacing a hand-written JSON decoder with `std.json` looks like a parser cleanup,
but a mature wire format carries behavior that is not described by its field types.
This contract format depended on raw escaped strings, raw structural keys, distinct
duplicate-field policies, overflow-to-default behavior, trailing-byte tolerance,
legacy field backfills, and an independently owned result.

The durable pattern is to treat the standard library as the syntax engine, not as
the compatibility policy. The implementation now has three explicit boundaries:

1. `std.json.Scanner` validates and advances through JSON syntax.
2. Typed wire DTOs preserve the old format's lexical and duplicate semantics.
3. A projection step allocates the owned domain graph and applies domain defaults
   and legacy backfills.

`parseFromJson` makes that lifetime boundary visible: it parses a temporary
`ContractWire`, defers destruction of the parsed arena, and returns only the
projected `HandlerContract` (`packages/zts/src/contract_json_parser.zig:428-435`).

The decoder rederive was preceded by a characterization matrix and a measured
branch baseline, so the implementation could be judged against observed behavior
instead of translating the old parser line by line
(`docs/plans/2026-08-04-019-code-quality-rebase-plan.md:226-253`).

## Guidance

### Make compatibility rules explicit wire types

Do not map compatibility-sensitive fields directly to ordinary decoded strings or
integers. Give each exceptional rule a small wire type.

- `json_wire.String` records the bytes between the JSON quotes without unescaping
  them (`packages/zts/src/json_wire.zig:9-21`). This preserves the established
  domain representation for strings and object keys.
- `json_wire.RawValue` records the exact source span of an embedded JSON value
  (`packages/zts/src/json_wire.zig:24-36`). The projection can then own those bytes
  without parse-and-reserialize drift.
- `json_wire.Unsigned(T)` consumes a syntactically valid decimal integer and maps
  an out-of-range value to `null`, which lets the owning DTO apply its documented
  default (`packages/zts/src/json_wire.zig:214-235`).
- `json_wire.OptionalNonNull(T)` distinguishes an omitted field from an explicit
  JSON `null` (`packages/zts/src/json_wire.zig:238-253`). The sandbox proof DTO uses
  it for proof hashes, where silently accepting `null` would
  erase a supplied proof claim (`packages/zts/src/contract_json_parser.zig:293-299`).
- `json_wire.AppendedNonNull(T)` gives sandbox capabilities the same null rejection
  while preserving repeated arrays inside one sandbox object
  (`packages/zts/src/json_wire.zig:255-287`).
- `json_wire.MergedOptional(T)` and `json_wire.AppendedOptional(T)` preserve the
  legacy rule that explicit null is a no-op for selected sections while repeated
  objects merge and repeated arrays append (`packages/zts/src/json_wire.zig:289-366`).
- `json_wire.FoldedOptional(T)` handles sections whose repeated-object policy is
  more specific than field-wise merging (`packages/zts/src/json_wire.zig:368-409`).
  Sandbox capability hashes are folded with the capabilities from the same object,
  so a hash cannot cross an occurrence boundary
  (`packages/zts/src/contract_json_parser.zig:293-309`).

These types keep the DTO declarative while preventing a generic decoder default
from silently changing the wire contract.

### Define duplicate and key semantics once

The recursive typed decoder reads structural keys through the raw string wrapper,
matches them byte-for-byte against field names, and skips unknown values
(`packages/zts/src/json_wire.zig:121-178`). This means an escaped spelling such as
`"versi\u006fn"` remains an unknown field instead of becoming `"version"` after
normalization.

Duplicate handling is shape-dependent. With the configured `use_last` policy,
ordinary scalar fields replace the earlier value, repeated slices append, and a
repeated plain object continues filling the same DTO
(`packages/zts/src/json_wire.zig:151-173`). Selected nullable sections add an
explicit merge or append policy so an intervening null does not erase earlier
wire facts (`packages/zts/src/contract_json_parser.zig:418-422`). Raw extension
maps keep insertion order, retain escaped keys as distinct keys, and replace an
exact duplicate through a temporary hash index
(`packages/zts/src/json_wire.zig:39-79`).

Keep this policy in the shared wire layer. Reimplementing it independently in each
DTO makes nested objects behave differently from the root and recreates the custom
parser as scattered code.

### Project borrowed wire data into an owned domain result

The wire arena may borrow spans from the input, but nothing returned to a caller
may depend on either lifetime. The projection therefore receives an allocator and
a `*const ContractWire`, initializes a domain value, and registers domain cleanup
before projecting child collections (`packages/zts/src/contract_json_parser.zig:438-450`).

For staged collection entries, initialize the owned value with an empty variant,
install `errdefer` cleanup, then fill allocation-bearing fields before appending.
The API response projection follows this sequence
(`packages/zts/src/contract_json_parser.zig:880-899`). Legacy backfills use the
same pattern for synthesized request bodies and responses
(`packages/zts/src/contract_json_parser.zig:915-955`). This keeps every allocation
failure on the same cleanup path as a successful domain object.

Projection is also where semantic boundaries stay separate. A decoded rate-limit
namespace can alias an already-owned cache namespace, but a rate-limit-only
namespace is owned separately rather than being appended to the cache
authorization list (`packages/zts/src/contract_json_parser.zig:1325-1345`). The
domain object records and frees that separate ownership explicitly
(`packages/zts/src/contract_types.zig:1760-1763`,
`packages/zts/src/contract_types.zig:1884-1888`).

### Verify behavior dimensions, not only representative documents

A decoder migration needs a matrix of focused compatibility probes. The current
tests pin scalar duplicate-last behavior, integer overflow defaults, and trailing
bytes (`packages/zts/src/contract_json_parser.zig:1504-1516`). They separately pin
raw structural keys, repeated collection appends, and repeated object merging
(`packages/zts/src/contract_json_parser.zig:1519-1540`). Repeated nullable sections
are covered across sandbox authority data, durable workflow metadata, behavior
arrays, and intervening nulls (`packages/zts/src/contract_json_parser.zig:1542-1567`).
Capability-hash scoping has a separate ordering matrix for cross-object and
same-object cases (`packages/zts/src/contract_json_parser.zig:1569-1600`). Explicit
null rejection for proof fields has its own negative matrix
(`packages/zts/src/contract_json_parser.zig:1602-1613`).

Ownership deserves an end-to-end lifetime test. The contract decoder test destroys
and overwrites its source buffer before asserting handler strings, raw schema JSON,
extension keys, and extension content
(`packages/zts/src/contract_json_parser.zig:1628-1646`).
Allocator correctness is checked across every failing allocation point in a fixture
that exercises extensions, legacy backfills, and rate-limit ownership
(`packages/zts/src/contract_json_parser.zig:1661-1692`).

Finally, keep the serializer's byte contract independent from decoder tests. The
build defines byte-identical public contract goldens specifically so a
behavior-preserving refactor cannot move serialized output accidentally
(`build.zig:662-672`).

## Why This Matters

Typed decoding improves clarity only when the old behavior remains visible. If the
standard decoder's defaults are allowed to define semantics, several changes can
hide inside an apparently mechanical rewrite:

- Decoded structural names can recognize inputs that were previously unknown.
- One global duplicate policy can erase or duplicate collection facts.
- Nullable optionals can turn an invalid explicit claim into an omitted claim.
- Integer overflow can become a hard error instead of selecting a default.
- Borrowed slices can escape the parsed arena or source buffer.
- Metadata can be projected into an authorization-bearing collection.
- Partial legacy synthesis can leak on allocation failure.
- Parse-and-reserialize can change canonical bytes.

The three-boundary design isolates these concerns. Syntax stays delegated to
`std.json`, wire compatibility is described by reusable types and recursive rules,
and the owned domain projection is the only place where defaults, authority, legacy
shape conversion, and allocation ownership are decided.

## When to Apply

- When replacing a custom parser for a persisted or externally consumed JSON format.
- When callers depend on lexical details such as raw escapes, raw embedded JSON, or
  trailing-byte tolerance.
- When duplicate fields historically use different rules for scalars, collections,
  maps, and nested objects.
- When omission, explicit `null`, overflow, and malformed input have different
  meanings.
- When parsed data must outlive the input buffer or parser arena.
- When legacy scalar fields must synthesize newer collection-shaped domain values.
- When decoded fields participate in security, proof, or authorization decisions.

## Examples

An overly direct migration lets generic defaults become the contract:

```zig
const Wire = struct {
    version: ?u32 = null,
    proofHash: ?[]const u8 = null,
    modules: []const []const u8 = &.{},
};

const parsed = try std.json.parseFromSlice(Wire, allocator, source, .{
    .ignore_unknown_fields = true,
});
```

That shape does not state what overflow means, cannot distinguish omission from an
explicit null proof hash, and leaves duplicate collections to one generic policy.

The compatibility adapter makes those decisions part of the wire vocabulary:

```zig
const Wire = struct {
    version: json_wire.Unsigned(u32) = .{ .value = null },
    proofHash: json_wire.OptionalNonNull(json_wire.String) = .{},
    modules: []const json_wire.String = &.{},
};

var parsed = try json_wire.parse(Wire, allocator, source);
defer parsed.deinit();

const owned = try projectDomain(allocator, &parsed.value);
```

The important property is not the wrapper names. It is that each compatibility
decision has one explicit owner, and the returned domain object crosses the parser
lifetime boundary only after all borrowed data has been copied into domain-owned
storage.

## Related

- [Bind self-extract runtime policy bytes into signed attestations](../security-issues/self-extract-runtime-policy-attestation-binding.md)
- [Sub-handler contract extraction must not inherit the strict profile](../security-issues/sub-handler-contract-extraction-strict-profile.md)
- [Cached Bytecode Teardown Leaked Roots on Allocator Failure](../runtime-errors/cached-bytecode-teardown-allocator-failure-leak.md)
- [Bind transient state to the object whose values it references](bind-transient-state-to-its-owner.md)
