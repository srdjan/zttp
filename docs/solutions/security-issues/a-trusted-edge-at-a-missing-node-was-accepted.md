---
title: A trusted edge at a missing node was accepted
date: 2026-09-24
category: security-issues
module: proof acceptance
problem_type: security_issue
component: tooling
symptoms:
  - "A certificate with 3 IR nodes that disclosed trusted evidence at node 7, with the inventory also naming node 7, was accepted under policy_mod.production."
  - "The evidence node bound ran only inside the rule-bearing branch, so a trusted edge (rule == null) was never checked against the IR node count."
  - "The trusted inventory never bounded .node family members, so a disclosure of a nonexistent node was taken as real."
  - "trustedEdgeDeclared truncated the u32 node id to u16, so node 65537 matched inventory node 1."
root_cause: missing_validation
resolution_type: code_fix
severity: critical
related_components:
  - "proof-checker acceptance"
  - "proof certificate evidence"
  - "trusted inventory"
tags:
  - "proof-checker"
  - "proof-certificate"
  - "fail-open"
  - "bounds-check"
  - "integer-truncation"
  - "trusted-evidence"
  - "releasefast"
  - "tamper-probe"
---

# A trusted edge at a missing node was accepted

## Problem

`packages/proof-checker` is the consumer-side acceptance kernel. It must refuse any certificate whose evidence does not point at something the consumer can see. Before the fix, it accepted a certificate that disclosed a trusted edge at an IR node that does not exist, under the production policy.

Three gaps combined. First, `checkEvidence` bounded `entry.node_id >= self.certificate.ir.len()` only inside `if (entry.rule) |rule|` (pre-fix `packages/proof-checker/src/checker.zig:1231`). A trusted edge must have `rule == null`, because `validEvidenceShape` requires it (`packages/proof-checker/src/checker.zig:1426`, the `.solver, .trusted => entry.rule == null` arm). So the node id of a trusted edge was never bounded. Second, the trusted inventory loop in `checkEvidence` did not bound the `member_id` of a `.node` family entry. Third, `trustedEdgeDeclared` compared `edge.member_id == @as(u16, @truncate(node_id))` (pre-fix `checker.zig:1406`). `member_id` is `u16` on the wire (`packages/proof-checker/src/certificate.zig:342`) and `node_id` is `u32`, so node 65537 aliased node 1.

Fixed on local main in commit d8d31f06 (not yet pushed as of this writing, so the SHA can change on a rebase).

## Symptoms

No test failed and no gate objected. A probe showed the defect: a certificate with 3 IR nodes, one trusted evidence entry at `node_id = 7`, and a trusted inventory that disclosed `.node` member 7. `check(fixture.inputs(), policy_mod.production)` returned `accepted = true` and `rejection = null`. The same result came from trusted evidence at `node_id = 65536` against an inventory that disclosed node 0.

`scripts/check-proof-swallow.sh` covers `checker.zig` (line 59) and stayed green, because nothing was discarded. The kernel returned a wrong answer. `markDeclared` (`checker.zig:1011`) skips out-of-range evidence with `continue`, and that skip has a row in `scripts/proof-swallow.allow` (line 61). The row was correct in isolation: an unmarked node costs the producer a declaration. But no other stage refused the same evidence, so the skip was the only place that saw the bad node id, and it said nothing.

The defect is a wrong verdict, not undefined behavior: no out-of-range index is ever dereferenced, and `@truncate` is defined. The build mode matters for a different reason. Releases build with `-Doptimize=ReleaseFast` (`.github/workflows/release.yml:129`), and `build.zig:226-229` passes that `optimize` to the `zttp_proof_checker` dependency. Runtime safety is therefore off in production, and that is why the audit that found this defect inventoried every safety-sensitive builtin in the kernel.

## What Didn't Work

**Reading the rule path.** The bound `entry.node_id >= self.certificate.ir.len()` exists in the code, and a reader who finds it concludes that node ids are bounded. That is the trap. The check is correct but sits on one arm of the variant, the arm that also uses the node. The trusted arm carries the same reference and never reaches it.

**Reusing the Zig cache between mutants.** An earlier mutation probe in the same session used one `--cache-dir` for all mutants. For mutants that do not change the file size, the reused cache reported stale passes. Each mutant needs a fresh cache directory, or its verdict is not evidence.

**Trusting the swallow gate.** The gate sees discarded errors. This defect discarded nothing, so the gate could not see it. The allowlist row for `markDeclared` was also not a defect: its reasoning holds only while some other stage refuses the same evidence, and before the fix no stage did.

## Solution

The defect was found by a Zig safety audit. Because the kernel ships ReleaseFast, the audit listed every production-scope `@truncate`, `@intCast`, `@enumFromInt`, `unreachable`, `.?`, and `assert`, and traced each one to its input. The `@truncate` compare in `trustedEdgeDeclared` raised the question of whether `node_id` was bounded at all. It was bounded on one branch only.

The probe method: copy the leaf package to a scratch directory (it has its own `test_root.zig`), append one test, and run `zig test test_root.zig --cache-dir <fresh>`.

The fix makes three changes in `packages/proof-checker/src/checker.zig`.

**Hoist the evidence bound.** Before, inside the rule arm only:

```zig
if (entry.rule) |rule| {
    if (entry.node_id >= self.certificate.ir.len()) {
        return reject(.evidence_check, .proof_node_unknown, .{ .ir_node = entry.node_id });
    }
    const node = try self.certificate.ir.get(entry.node_id);
```

After, for every entry, directly after `validEvidenceShape` (`checker.zig:1204-1208`):

```zig
// Every edge names a node, whether or not it carries a rule. An
// edge at a node the IR does not have states nothing.
if (entry.node_id >= self.certificate.ir.len()) {
    return reject(.evidence_check, .proof_node_unknown, .{ .ir_node = entry.node_id });
}
```

**Bound inventory node members** in the trusted inventory loop (`checker.zig:1292-1294`):

```zig
if (edge.family == .node and edge.member_id >= self.certificate.ir.len()) {
    return reject(.evidence_check, .proof_node_unknown, .{ .ir_node = edge.member_id });
}
```

**Widen the compare** in `trustedEdgeDeclared` (`checker.zig:1412`). Before:

```zig
if (edge.family == .node and edge.member_id == @as(u16, @truncate(node_id))) return true;
```

After:

```zig
if (edge.family == .node and @as(u32, edge.member_id) == node_id) return true;
```

The fix reuses the reason code `proof_node_unknown`. The published vocabulary envelope and the policy hash did not move. A new code would move the hash and need `scripts/verify.sh` and re-pinning.

Three tests were added: "trusted evidence at a node the proof IR does not have rejects", "trusted evidence does not match an inventory node that differs above sixteen bits", and "an inventory node the proof IR does not have rejects".

One limit is honest to state: the widened compare has no independent test. A node above 65535 needs more than the default `max_ir_nodes = 65_536` (`packages/proof-checker/src/limits.zig:24`). The second test rejects at the hoisted bound, not at the compare.

Verification: `zig build test-proof-checker` passed 186/186. `test-proof-checker-purity`, `test-proof-swallow`, `test-cli` (820 tests: 819 passed, 1 skipped), `test-proof-ratchet` (51), and `test-invariant-drift` all exited 0.

## Why This Works

A node id in a certificate is a reference into the IR table. A reference is valid only when it is inside the table, and that is true for every variant that carries the reference, not only for the variant that dereferences it. The old code tied the bound to the use: the rule arm reads the node, so the rule arm checked it. The trusted arm does not read the node in `checkEvidence`, but its node id still reaches `markDeclared` and `trustedEdgeDeclared`, where it has meaning. The hoisted bound now runs for every entry before any arm, so no later stage receives an out-of-range node id.

The inventory entry is a second reference into the same table, from a different section. It needed its own bound, because a disclosure that points at nothing can match evidence that also points at nothing.

The widened compare removes aliasing. Truncation maps many `u32` values onto one `u16`, so a compare after truncation answers "equal modulo 65536". Widening the narrow side keeps the compare exact.

With the bound in `checkEvidence`, the `markDeclared` skip and its allowlist row stay correct: the evidence that the skip ignores is now also refused, so the skip can no longer be the only stage that sees it.

This is the same class as [empty-label-set-claimed-a-value-was-clean](empty-label-set-claimed-a-value-was-clean.md) in one respect: an analysis file that decides a verdict returned a pass that claimed more than it checked, and the swallow gate stayed green because nothing was discarded. The mechanism is different: a missing bound on one variant, not an empty value that stood for "not looked".

## Prevention

**Put a reference bound where every variant passes.** A bound that validates a reference goes on the path that every variant carrying the reference takes, not inside the one arm that also uses it. When you find a bound, ask which variants skip it.

**Probe each variant with an out-of-range reference.** For each variant of a tagged record that carries an id into another table, build one fixture with the id at `table.len()` and require a rejection. This is the test that catches the defect:

```zig
test "trusted evidence at a node the proof IR does not have rejects" {
    var fixture = try test_support.build();
    const absent: u32 = @intCast(fixture.parts().ir.len);
    fixture.evidence[0] = .{
        .obligation_index = 0,
        .edge = .trusted,
        .rule = null,
        .node_id = absent,
        .aux = 0,
    };
    const trusted = [_]cert_mod.TrustedEdge{
        .{ .family = .node, .member_id = 0, .reason = .not_modeled, .grade = .trusted },
        .{ .family = .node, .member_id = @intCast(absent), .reason = .not_modeled, .grade = .trusted },
        .{ .family = .opcode, .member_id = 0, .reason = .not_modeled, .grade = .trusted },
    };
    var parts = fixture.parts();
    parts.trusted = &trusted;
    try fixture.encodeParts(parts);

    const result = check(fixture.inputs(), policy_mod.production);
    try testing.expect(!result.accepted());
    try testing.expectEqual(verdict.Stage.evidence_check, result.rejection.?.stage);
    try testing.expectEqual(verdict.ReasonCode.proof_node_unknown, result.rejection.?.code);
    try testing.expectEqual(absent, result.rejection.?.subject.ir_node);
}
```

The inventory discloses the same absent node on purpose. The disclosure is what let the pre-fix kernel accept the certificate, so a probe without it does not reproduce the accepting path.

**Bound every cross-table entry.** A disclosure or inventory entry that references another table needs its own bound. Agreement between two sections does not make either reference real.

**Widen, never truncate, to compare ids.** When you compare a narrow stored id to a wide one, widen the narrow side. A `@truncate` in a compare is an aliasing bug unless a bound above it makes the high bits zero.

**Audit safety builtins in a ReleaseFast kernel.** In a kernel that ships ReleaseFast, list every production-scope `@truncate`, `@intCast`, `@enumFromInt`, `unreachable`, `.?`, and `assert`, and trace each to the guard that makes it safe. That audit found this defect.

**Use a fresh cache for each mutant.** A reused `--cache-dir` can report a stale pass for a mutant that keeps the file size.

**Open item.** Building the kernel dependency ReleaseSafe would turn a missed guard into a panic instead of undefined behavior. The cost is not measured; this needs to be measured before a decision.

## Related

- [Bind proof authority into the signed executable root](proof-certificate-authority-was-outside-the-signed-root.md): an earlier `missing_validation` fix in the same checker. It added structural checks on evidence and IR, but did not bound evidence or inventory node ids.
- [A gate can be non-vacuous and still porous](../conventions/a-gate-can-be-non-vacuous-and-still-porous.md): the bound fired on its probed arm, and the unprobed arm was the hole.
- [Proof-checker rederive review](../../plans/2026-09-24-proof-checker-rederive-review.md): section 5 records this fix and the kernel build-mode decision. Section 4 lists the other unpinned refusals found by the mutation probe.
