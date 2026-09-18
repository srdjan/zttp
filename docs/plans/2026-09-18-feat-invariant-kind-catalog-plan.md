# ZTTP Invariant Kind Catalog

## Purpose

Grow the accepted invariant catalog from one closed template to a closed, gated
set of kinds over the existing protected ledger. The developer selects a kind
from a list the build generates. Deterministic builds consume the canonical
specification. Model output never authorizes an artifact.

This plan continues `2026-09-18-feat-application-invariants-plan.md`, whose
Boundaries section defers general predicates. It does not lift that deferral. It
replaces one closed template with a closed catalog, which is a different thing.

The claim this design makes, and the only one it makes:

> Every predicate the protected ledger enforces is offered for selection, and a
> gate proves that the enforced set, the `Kind` enum, the offered list, and the
> adapter identity agree.

The word "conclusive" is not used, because no gate can establish it. "Closed,
with a stated admission criterion and a gate" is testable and is what the
product needs.

## Admission criterion

A protected store is a module that owns, for its own data, atomic commit,
writer isolation, replay idempotence, and a baseline it validates when it opens.
`zttp:ledger` owns all four: `BEGIN IMMEDIATE` in `executePost`
(`packages/modules/src/data/ledger.zig:267`), an idempotency row plus content
hash making a retry a no-op (`:271`), entries and balances committed in one
transaction (`:311`), and `bootstrapOrValidate` under `BEGIN EXCLUSIVE` (`:181`).

An invariant kind is a developer-selected predicate that such a store evaluates
on every write and on the baseline. Because the store owns the four properties,
no induction is required and none is claimed: the per-write evaluation is the
inductive step with its preconditions discharged by construction, and baseline
validation is the base case.

Two hook points exist, and every admissible kind names one:

1. **Group predicates**, decidable from the posting group alone, evaluated in
   `validateGroup` (`:433`) before the transaction opens. Conservation is one
   today: `if (sum != 0) return error.Unbalanced` (`:437`).
2. **State predicates**, needing current balances, evaluated inside the
   transaction after the per-account `next` is computed and before the balance
   upsert (`:303`).

A proposed kind that fits neither hook is refused. In particular, program-shape
properties ("the idempotency key derives from the business id", "no balance
value reaches a response") need operand-level bytecode observation, which
`invariant_observer.zig` already carries as its most fragile part. Those belong
to the flow checker, which has the label machinery, and are not kinds.

## The change that kind 2 forces

Today `validateGroup` enforces conservation unconditionally, for every caller,
whatever the configured specification says. The configured kind is therefore not
a selector. It is an identity binding: it fixes what the certificate and the
checker agree the artifact claims.

A second kind changes that. The module must then enforce exactly the configured
set, which creates a failure mode that cannot occur today: an artifact whose
specification names a kind that the linked adapter does not enforce. Acceptance
would pass, because the checker verifies call-site honesty and spec identity,
not predicate behaviour.

`invariant.adapter_identity` (`packages/proof-checker/src/invariant.zig:137`,
today the fixed string `"zttp:ledger/native-adapter-v1"`) is what closes this,
and it must stop being a hand-written constant. It becomes a function of the
enforced predicate set, so an adapter that enforces a different set cannot
present the same identity. This is the load-bearing safety change in the plan,
and it is why item 4 precedes item 5.

## Implementation

1. **Replace the Python authoring tool with a Zig command.** `zttp invariant
   list` prints the offered kinds with their canonical descriptions. `zttp
   invariant author` prints a reviewable candidate and never writes an accepted
   specification. Delete `scripts/invariant-author.py`. The optional advisory
   classifier keeps its existing boundary, which is that only the developer's
   sentence leaves the machine, never code, ledger contents, or credentials.
   Inject the HTTP transport the way `smt_solver.zig` is injected, so no network
   client enters the `zts` analyzer or the wasm build.

2. **Move the per-kind canonical description into Zig beside `Kind`** and derive
   the offered list from it at comptime, the way `property_goals.zig` derives
   `supported_goal_list` from `supported_goals`. The description is the sentence
   the developer confirms, so it is authored once and read everywhere.

3. **Make the canonical bytes a tagged payload set.** Today the layout after the
   header is the conservation payload, hardcoded in `invariant.decode` (`:75`)
   and again in `invariant_config.parse`. Replace it with a sorted list of
   (kind, payload) records under one digest. Keep exactly one specification
   member per artifact, so the checker's `spec_members != 1` identity binding
   (`packages/proof-checker/src/checker.zig:464`) is unchanged. Replace
   `verdict.kind_bits`, today a `u8` (`verdict.zig:323`) set by a shift
   (`checker.zig:479`) and so capped at eight kinds, with a `u32` mask. A mask
   keeps the verdict's per-kind reporting; a plain count would lose which kinds
   were accepted.

4. **Make enforcement read the configured set, and derive the adapter identity
   from it.** The module gains a table of enforced predicates keyed by kind, and
   the identity string is computed from that table rather than written by hand.
   Conservation stays unconditional in the shipped adapter so no existing
   artifact changes meaning; it is simply also a member of the enforced set.

5. **Add `declared_accounts_v1` as kind 2.** Every entry's account matches a
   declared class pattern. It is a group predicate, decidable in
   `validateGroup`, needing no state read and no observer change. It is chosen
   first because it is the cheapest predicate in the catalog, so items 2, 3 and
   4 get designed against the easy case rather than under pressure from a hard
   one. Baseline extension: scan `ledger_balances` accounts against the patterns.

6. **Fix two defects in the shipped tool and checker.**
   - The authoring tool emits `balance_conservation_v1` for any sentence when
     the advisory is not requested, because `render` treats `not_requested` as
     permission and no `--kind` flag exists. The Zig replacement requires an
     explicit kind selection, prints the kind's canonical description directly
     under the developer's sentence, and records `reviewed_against` rather than
     a free-text `statement` that nothing relates to the kind.
   - A zero-write artifact reaches ready. `invariant_operation_required`
     (`checker.zig:470`) refuses only when the certificate list and the observed
     list are both empty, so an artifact with one `balance` read and no `post`
     passes coverage while the invariant holds vacuously. Add a per-kind write
     floor: a kind that constrains writes requires at least one observed write
     site, or the verdict states the result is vacuous.

7. **Extend the drift gate and retire its Python.** `scripts/check-invariants.sh`
   compares fifteen paths and does not include the authoring tool, so the
   offered list and the `Kind` enum can disagree with nothing failing. Rewrite
   the gate as a Zig build step that compares four surfaces: the `Kind` enum,
   the per-kind descriptions, the enforced predicate table in `ledger.zig`, and
   the adapter identity. Keep the existing non-empty-input assertion on every
   compared source, which is the floor that makes the count mean something.

8. **Rename the verdict summary.** The current line reads as "invariant
   verified" to a reader who has not read `docs/verification.md`. State the
   facts separately and in the order a reader needs them: enforced by the native
   adapter at each post (trusted); N of N declared ledger call sites
   independently observed; baseline validated at instance open; external writers
   excluded by deployment (not checked). The last clause is not suppressible.

## Validation

Start with a candidate for a sentence that does not describe conservation, and
confirm the tool refuses rather than emitting conservation. Then a two-kind
specification that round-trips through encode, decode and the checker. Then an
artifact whose specification names kind 2 against an adapter that does not
enforce it, which must be refused by identity. Then a read-only artifact, which
must report vacuous rather than ready.

Extend to declared and undeclared accounts, baseline stores that violate a newly
configured kind, kind ordering in the canonical bytes, duplicate kinds, an
unknown kind ordinal, and a specification whose digest does not match the
certificate. Retain every existing invariant test, including retries, restart,
interrupted commits, concurrent writers, and tampered specifications.

Run the affected module, SDK, compiler, checker, artifact and runtime suites,
plus proof-checker purity, capability, module governance, boundary,
proof-swallow and stand-in gates. Run `test-zruntime` separately.

## Boundaries

Kinds are added over the existing protected ledger. New protected stores are a
separate program and are not in scope; the tagged payload, the generated offered
list and the gate all generalize to one when it is built, which is the reason to
do this first.

`account_floor_v1` and `transfer_topology_v1` are the next two candidates and
are not in this plan. Cross-currency and cross-ledger conservation stay deferred
for the reason the previous plan gives, that no single lock covers them.
Temporal predicates need a sweeper and a clock and are not per-post decidable.
Unconditional module guarantees such as idempotent posting are documentation,
not selectable kinds, and must stay out of the offered list so they do not
dilute a selection question.

Existing algebraic law metadata in `semantics.zig` keeps its name and is
unrelated to this catalog.

Work on local main and commit complete isolated units. Do not push.

## Open measurements

Baseline validation runs per handler instance under an exclusive lock, and every
kind adds a baseline check. The previous plan already records that its cost on a
large ledger needs measurement and that a new instance's validation lock can
conflict with active posting. That measurement gates how far the catalog grows
and must be taken before kind 3, not estimated.

The four surfaces the new gate compares must be checked by deleting each input
in turn and confirming the gate fails, because a gate whose input is empty
reports a pass while checking nothing.

## Out of scope, recorded

The repository contains four tracked Python scripts and fifteen shell scripts
that invoke `python3`. This plan removes the two that belong to the invariant
feature, `scripts/invariant-author.py` and the Python body of
`scripts/check-invariants.sh`. The rest is legacy to remove as each area is
touched, per the rule now recorded in `AGENTS.md`.
