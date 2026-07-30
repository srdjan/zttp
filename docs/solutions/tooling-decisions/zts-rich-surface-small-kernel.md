---
title: Balance a rich ZTS surface with a small certified kernel
date: 2026-07-30
category: tooling-decisions
module: ZTS language profile
problem_type: tooling_decision
component: tooling
severity: high
applies_when:
  - "Designing or extending the certified ZTS application profile"
  - "Evaluating a TypeScript feature for admission into ZTS"
  - "Making language acceptance or proof-certificate claims"
tags:
  - zts
  - language-design
  - formal-semantics
  - type-system
  - proof-boundary
  - application-profile
---

# Balance a rich ZTS surface with a small certified kernel

## Context

A restricted TypeScript profile can fail in two opposite ways. Minimizing
source syntax too aggressively makes ordinary application code awkward and
pushes missing capabilities into native extensions. Importing TypeScript's
full dynamic and type-level surface makes semantics, effect analysis, replay,
and independent verification too broad to close.

The advanced ZTS profile resolves this tension by optimizing for few semantic
concepts, not merely few source tokens. Its target is a useful application
surface that elaborates locally into a much smaller execution kernel. The
complete proposal is
[ZTS advanced formal-spec northstar](../../zts-formal-spec-northstar-advanced.md).

## Guidance

Use the rule: rich application surface, small certified kernel.

Admit a feature only when all of these tests pass:

1. **Application evidence**: representative HTTP, HTML, event, queue,
   workflow, or pure-domain code needs it without a checker bypass.
2. **Canonical form**: it adds one clear spelling instead of a competing way
   to express an existing operation.
3. **Local elaboration**: it lowers to a bounded set of explicit kernel forms
   without reflection, prototype lookup, hidden receiver binding, or ambient
   scheduling.
4. **Closed semantics**: every reachable node, intrinsic, value kind, opcode,
   and module effect has a specified disposition.
5. **Property honesty**: accepting the feature does not imply termination,
   bounded cost, or end-to-end proof unless those separate obligations are
   discharged.

Spend expressiveness in types and pure libraries before adding control syntax.
The advanced profile therefore completes sound generics and contractive
recursive aliases, and standardizes `Result<T, E>`, `Dict<K, V>`, immutable
`Bytes`, typed HTML nodes, explicit JSON `null`, typed codecs, and precise
application capability contracts. These additions cover common application
data without introducing exceptions, classes, promises, reflection, dynamic
imports, arbitrary loops, or TypeScript type metaprogramming.

Keep language admission and certification separate:

- A build report records what ran and what remains unsupported.
- A checked report records completed audits without claiming every theorem.
- A proof certificate names its properties, binds the exact artifacts and
  assumptions, covers the closed profile, and is accepted by an independent
  verifier.

Unknown solver results, partial semantic coverage, unchecked recursion, or
self-declared native-module behavior can reduce the available proof grade.
They must not be relabeled as successful proof.

## Why This Matters

This boundary keeps ZTS useful for general application programming while
preserving a tractable trusted computing base. Applications can express typed
errors, keyed data, recursive trees, binary payloads, JSON, rendering, and
compositional effects directly. The verifier still reasons about a closed
kernel with visible control flow and capability calls.

The distinction between acceptance and certification also prevents a useful
language feature from being rejected merely because one optional property is
not yet provable. Conversely, it prevents a successful compile or partial
analysis from being presented as a stronger assurance result.

## When to Apply

- When a proposed syntax feature has no representative application corpus
  case.
- When application code needs native escape hatches for routine data or error
  handling.
- When two source constructs would express the same operation.
- When a feature introduces hidden control flow, authority, or scheduling.
- When a report uses proof language without a closed theorem chain and an
  independent consumer.

## Examples

`Result<T, E>` adds typed recoverable failure without adding `throw`,
`try`, or `catch`. It is source-level expressive power that elaborates to
tagged records and explicit branches.

`Dict<K, V>` adds deterministic dynamic keyed data without allowing computed
keys to mutate fixed-shape records. It supplies one collection contract
instead of inheriting JavaScript object and prototype behavior.

Recursion is accepted for recursive application data, but termination and
cost certificates require a proved decreasing measure. Syntax acceptance and
property proof remain separate decisions.

## Related

- [ZTS advanced formal-spec northstar](../../zts-formal-spec-northstar-advanced.md)
- [Earlier formal-spec northstar](../../archive/spec-explainers/zts-formal-spec-northstar.html)
