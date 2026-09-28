# Concepts

Shared domain vocabulary for this project: entities, named processes, and status concepts with project-specific meaning. Seeded with core domain vocabulary, then accretes as ce-compound and ce-compound-refresh process learnings; direct edits are fine. Glossary only, not a spec or catch-all.

## Proving a handler

### Handler
The single function a deployed program exposes, taking a request and returning a response. It is the unit the compiler proves: properties, capabilities, and declared obligations are all stated about a Handler, and helpers it calls are judged by what they contribute to it.

### Handler Contract
The compiler-produced record of a Handler's discovered routes, effects, Capabilities, API shape, proof results, and integrity hashes. It is the shared boundary carried from analysis into serialization, attestation, runtime policy, and system linking.

A decoded Handler Contract is input claimed by its serialized source, not a fresh proof created by decoding. Consumers must preserve that distinction when using its fields for verification or authority.

### Property
A fact the compiler either proves about a Handler or declines to prove, such as whether it leaks a secret, answers the same way on every run, or is safe to retry. A Property is never partially held: it is proven, or it is not, and an unproven Property is reported rather than assumed false-and-forgotten.

Some Properties are derived from others rather than observed directly, so a change to what decides one silently changes the derived one. Anything deriving a Property must be recomputed after the deciding answer lands, not before.

### Proof profile
The set of Properties a Handler must discharge. A Handler that declares nothing is held to the full default profile; one that declares a Spec is held to exactly what it declared. Declaring a narrow Spec is how an author trades a proven guarantee for the freedom to do something the full profile forbids.

### Spec
An author's declaration, written on the Handler's return type, of which Properties it claims. The compiler discharges each claim against what it inferred; a claim it cannot discharge is an error, not a warning.

### Proof capsule
A Spec written as a wrapper around the declared return type, so the claim travels with the value it is made about. The form is the same on a Handler and on a helper, and the compiler names it this way when it reports an undischarged claim on either, so the term is not a helper-only one.

A capsule is what lets a proof compose across a call boundary: without one, a helper that breaks a Property the Handler needs makes the Handler's proof fail, because nothing states what the helper promises.

A capsule written into a fixture is a claim about a program that does not exist yet, and it can stop being satisfiable without being edited. When a rule change elsewhere makes some Property unprovable for the shape the fixture asks for, every answer to it becomes an error, and the capsule still reads as a reasonable request.

### Effects ceiling
A declared upper bound on the Capabilities a function may reach. The inferred set must sit inside the ceiling; reaching past it is an error, and declaring a Capability never reached is a warning, so the ceiling stays honest in both directions.

## Accepting an artifact

### Deployment artifact
A self-contained binary, also called a self-extracting binary: the runtime
executable with one handler's payload appended - its bytecode, contract, policy,
certificate, and the declaration and tool catalog when it has them - and a fixed
trailer at the end that frames that payload.

Whether a binary is an artifact is decided once, from the trailer's framing
alone. A binary whose trailer frames no payload is a plain runtime and may serve
a project from source. A binary whose trailer frames a payload is an artifact
from then on: a payload that is damaged, too large, or unreadable refuses to
start, and never falls back to running as a plain runtime.

### Executable graph
The ordered inventory of every byte and identity that can affect what a
deployment runs: the entry module's bytecode, each dependency in load order,
every function, every constant pool, the module and native-module identities,
the contract, the runtime policy, the source profiles, the grammar, the
semantics registry, the capability matrix, the proof IR, and a digest over every
authority-bearing certificate section. It folds to one root. Order is part of
the commitment, and the producer and the consumer build their inventories
independently from the same bytes. That independence is what makes comparing
them worth anything.

### Certificate
What a producer attaches to an artifact so a consumer can check it: the
canonical proof IR, the obligations it discharges, the evidence for each, the
translation witnesses relating the IR to the final bytecode, and the executable
graph the whole thing is about. It is data, not authority. A certificate is
never believed; it is decoded, re-derived against, and either accepted or
refused. Its cycle-safe digest normalizes only the executable-root slot and its
own graph-member slot; every other certificate byte changes the signed root.

### Acceptance kernel
The consumer-owned checker that decides whether an artifact may serve. It
reconstructs the obligations from the proof system's rules rather than reading
the producer's list, folds totality itself rather than reading the producer's
answer, and re-relates the translation witnesses. It is a leaf with no I/O, no
allocator, and no dependency on the compiler or the server, so what an auditor
has to read to trust an acceptance is one directory.

Its runtime safety checks stay on in release builds, so a guard it lacks turns
bad input into a refusal to serve rather than undefined behavior. That holds
only because each of its functions turns safety on in its own body: the build
mode of the module that contains it does not decide this.

### Assurance grade
How strong the weakest link in a certificate's chain is: proved, translation
validated, solver assumed, tested, or trusted. An obligation's grade is the
weakest edge actually used to establish it, and an artifact's grade is the
weakest across the properties the consumer required. A grade is never averaged
and never rounded up.

### Disclosed edge
A step in the chain the consumer did not check and the certificate says so:
a corpus that exercised something, a family the kernel does not model, an axiom
from outside the artifact. Disclosing an edge is not a weakness in the design;
failing to disclose one is. The published set of them is the residual trusted
boundary, and shrinking it one family at a time is the ratchet.

A disclosure has to name something the artifact contains. An edge disclosed at
a proof node the certificate does not have is refused, even when the evidence
names the same absent node: agreement between two sections of a certificate
does not make either reference real.

### Proof-checked contract
A handler contract an acceptance has promoted. Only this drives behavior that is
unsound if a compiler claim is wrong - the proof response cache, unbounded
runtime reuse, the result and optional safety shortcuts, the durable-workflow
guarantees. Promotion copies only properties that cleared the active consumer
policy; unrelated or below-floor compiler claims remain false. Its counterpart,
the integrity-bound contract, says only that the contract describes the artifact
that was loaded, which makes its claims readable but checks none of them.

### Residual guard
A consumer-owned obligation for a capability resource the compiler could not
resolve statically. The certificate names the operation, but the acceptance
kernel reconstructs its kind, normalization, policy section, sink, and
implementation identity from its own catalog. Exact coverage and the exact
serialized runtime policy must be accepted before activation.

A residual guard is not a Property. Its three answers stay separate: producer
property facts, consumer coverage of the guard plan, and the live sink's allow
or deny decision for one resource under one policy generation.

### Application invariant
A versioned condition that every committed change to protected application
state must preserve. The catalog is closed and holds two: balance conservation
for one declared ledger and its currencies, which acceptance requires of every
specification, and a declared account set, which is optional and admits only
the accounts a specification names by exact bytes or by prefix.

The author confirms a structured specification. The executable graph binds
that specification and the protected adapter. The acceptance kernel then
matches the proof IR, translation witnesses, and ledger calls that the runtime
finds independently in final bytecode. This produces an Invariant verdict. The
verdict stays separate from Property and Residual guard verdicts.

The invariant has two parts. Consumer coverage shows that all protected calls
use the named native boundary. Runtime enforcement makes each posting atomic,
rejects a posting whose signed entries do not sum to zero, and rejects one
naming an account the specification does not declare. Coverage does
not convert the native boundary into a static proof. The accepted artifact
therefore records the native adapter as a trusted dependency.

A status report over an Application invariant reads write applicability first,
because coverage counts call sites and not calls that ran. It names the
declared kinds, keeps coverage separate from the ledger baseline that only a
live instance can validate, and always states that excluding other writers
from the store is a deployment assumption nothing here verifies. It never
calls a predicate proven, and it never renders the author's plain-language
sentence as a checked claim.

### Guarded generation
One immutable runtime tuple containing the executable root, proof-checked
contract, residual plan, decoded policy index, and policy generation. Startup
installs none of it until proof acceptance succeeds. Certificate-free live
reload cannot replace or create a Guarded generation, and a failed candidate
leaves the previous tuple and its in-flight requests intact.

## Tracking data through a handler

### Data label
A mark on a value recording where it came from: an environment secret, a caller's credential, request input, a clock or randomness read, or an explicit record that the analysis could not tell. Labels propagate through the operations a value passes through, so a value assembled from a labelled one carries the label.

The empty set of labels is a positive claim that a value carries nothing, not an absence of information. Code that cannot determine a value's provenance must say so with the label that means "could not follow", because returning the empty set instead asserts cleanliness the analysis never established. This bites hardest at a module call, where propagation is not automatic: an export is a propagator only when it declares that its result can hold what it was handed, and one that declares nothing is read as claiming its result holds nothing.

The "could not follow" label belongs only to a value the analysis genuinely cannot trace, such as the result of calling a function value with no resolved body. A call whose behavior the analysis knows, such as a built-in method on a string, keeps its ordinary labels. Applying the label more widely does not make a false pass; it makes a false refusal of a correct program.

### Declassifier
An operation entitled to clear one named Data label, because performing it is what that label's discharge means. Validation clears the "came from the request" mark, and a Replay boundary clears the "differs per run" mark.

The entitlement is per-label and never general. A Declassifier still carries every other label its input held: a validated secret is a secret, an escaped secret is a secret, and a recorded secret is a secret. Conflating "this operation clears a label" with "this operation clears the labels" is the recurring way a disclosure Property comes to be proven over a value that discloses.

### Sink
A position where a value leaves the program, such as a response body, a log, or an outbound request. Sinks are where Data labels are judged: a label arriving at a Sink is what costs a Property, and each Sink decides a different set of Properties, since a value reaching a log is not the same disclosure as one reaching a client.

A Sink is judged only inside a function the analysis walks. A Sink in a function that no Analysis root reaches costs nothing, so the Property it should have cost is reported as held.

### Analysis root
A function that a property analysis walks from its first statement as a place where request data enters user code: the Handler, and every function the Handler can dispatch to indirectly, such as each route of a literal routing table.

A Property holds for a program only when every Analysis root is walked. An indirect call whose target set the analysis can resolve contributes each target as a root, and its value carries the union of what those targets return. An indirect call whose target the analysis cannot resolve carries the label that means "could not follow", so it cannot help prove anything.

### Capability
A kind of authority a function reaches for: reading the clock, drawing randomness, reading configuration, writing to storage, talking to the network. Capabilities are declared per module export and enforced where the call happens, so authority is visible in the contract rather than discovered at runtime.

### Execution Context
The isolated engine state that owns a JavaScript stack, globals, module state, runtime policy, the authorization for its current native-module call, and any structured-I/O collection scope active for that execution.

### Active module scope
The module identity and declared Capabilities authorized for the native-module call currently executing inside one Execution Context.

Each Execution Context owns at most one active scope at a time. Nested calls replace and restore that scope locally; if panic recovery skips restoration, the failed Context is quarantined and revokes the scope before teardown callbacks run.

### Module handle
An opaque token given to a native module that identifies the Execution Context whose authorization and module-state bridge operations must use.

### Replay boundary
A point where a value is recorded on the first run and reproduced on later ones. Values crossing it stop varying between runs, so the marks that mean "differs per run" are cleared there. Marks about disclosure remain, because a recorded secret is still a secret when replayed.

## Typing a handler

### Narrowing
The compiler's flow-sensitive refinement of a binding's type inside the region a test proves something about it, held apart from the declared type so it can be discarded without losing the declaration.

The set of tests admitted as evidence is closed and small: a value compared against one of the two absent values, a `typeof` comparison, an array test, a discriminant field compared against a literal, a bare boolean discriminant read, and the negation or conjunction of those. A test outside the list installs nothing, because a refinement the compiler cannot re-derive is a claim rather than a proof. A Narrowing is killed when the binding is assigned, when a loop body may assign it, and when the branch that established it closes - the last because a refinement established under a condition says nothing about the path where that condition was false. Admission is decided on the form of a test and never on whether that test would refine this particular declared type, since an admitted test over a type with nothing to refine is still an admitted test.

### Absence sentinel
The one value that means "not there": a missing optional field, a lookup that found nothing, a parameter left off. Its counterpart is data that happens to be empty, which the language spells with a separate value and admits only where the declared type names it - so a type that carries the second value is not a type that may be absent.

Keeping them apart is compiler-enforced rather than remembered, because the two operators that supply a default and read through an absent value test both alike and would silently erase the distinction. Those operators are refused on any operand whose type admits the data value, and on a type parameter or the top type, where a later instantiation could admit it. A test against one of the two says nothing about the other: a guard that removes absence leaves the data value in place, and a helper that removed both would claim a refinement the test never established.

### Contractive alias
A recursive type whose every cycle passes through a value constructor - a record, a tuple, an array - and which therefore describes finite values.

Contractivity is what makes recursion admissible rather than an infinite type: the compiler unfolds a guarded cycle with a memoized pair comparison and never expands it. A union or intersection edge does not guard, so a type that names itself through only those, directly, or through a function parameter is refused. The check is decided once over the whole type namespace, after it closes, so a forward reference is not mistaken for a cycle.

### Type-test pattern
A `match` arm that selects on a value's kind rather than on its contents, covering the closed set of core value kinds.

Each test lowers to the corresponding admitted Narrowing test, so a type test adds no evidence the compiler could not already re-derive, and it narrows the scrutinee for its arm the same way. Together with literal patterns it is what lets a heterogeneous union be taken apart exhaustively without a catch-all arm, which a closed union is required to do without.

### Pattern binding
A `match` record-pattern field that names the field instead of testing it, introducing an arm-scoped constant of that field's narrowed type.

A binding constrains nothing - the discriminant tests in the same pattern do the selecting - and it is the idiomatic way for an arm to read a field, in place of reading it back off the scrutinee. Its scope is the arm: the name is not in scope in a sibling arm or after the match.

### Type predicate
A declaration that a function's true return means its named parameter has a narrower type.

The declaration is a claim, not a proof: it installs a Narrowing at its call sites only when the body is a single return of admitted tests over the named parameter. Any other body keeps the declaration, reports the refusal, and installs nothing - the half that matters, since a guard the compiler cannot check is a refinement the author asserted and nothing confirmed.

### Union normalization
The rewriting every union goes through as it is constructed, so that any two ways of spelling the same union yield the same member sequence: nested unions are flattened, the empty type is dropped, structurally identical members collapse to one, and a member describing no value another member already describes is dropped. One surviving member is that type rather than a union of one; no survivor is the empty type.

Normalization may lose canonical quality and must never lose a member. Every member of a union on the source side of an assignability check is a separate obligation, so a member dropped by a bounded or simplifying path turns a rejection into an acceptance. Constructing a union from a single existing union returns that same union unchanged, which is the identity contract callers build on.

### Canonical key
A structural fingerprint of a type, used to decide whether two separately built types are the same type. The type store does not intern, so two identical record shapes constructed at different moments occupy different positions in it; identity by position would read them as two distinct members of one union, and the key is what makes them one. It answers sameness of shape, never assignability between shapes.

## Measuring the compiler

### Veto
The compiler's refusal of a Handler that does not discharge its Proof profile. The Veto is the mechanism the project's central claim rests on: that the set of programs an agent writes converges on the set the compiler can prove.

At edit time the Veto answers a narrower question than its name suggests. It counts the violations a draft introduces *relative to a baseline* - the prior content of the file - and passes when that count is zero. It is not a compare-and-swap against what is on disk, and it has no opinion on what the draft removes: deleting correct code introduces no violation. A caller that supplies an empty or absent baseline therefore gets a clean verdict from a working Veto, which is how a destructive edit once proved clean.

### First-draft veto-pass rate
The share of prompts whose first generated attempt clears the Veto with no retries, counted over a frozen corpus. Retries are excluded deliberately because a rate counting them would measure a retry loop's persistence rather than the agent's aim.

### Bounded provable-set reach
The fraction of a frozen reference-backed task suite that a fresh model run completes within fixed limits.
Each reference and generated handler must pass the same absolute compiler checks, required properties, and runtime acceptance checks.
Every selected task stays in the denominator, including failures.
A deterministic harness run, replay, or partial pilot does not establish the full-suite fraction.
The result describes that suite, not every program the compiler can prove.

### Policy hash
A fingerprint of the compiler's rule set, recorded beside every published rate so two measurements taken under different rules are never compared as though they were the same. It covers the rules and not the analysis behind them, so a change to what a rule concludes can leave it identical; the build a measurement came from is what distinguishes those.

### Corpus identity
A fingerprint of everything a measured agent was shown: for each case, what it was asked, the workspace it was given, and how the task was posed. It is the companion of the Policy hash, which fingerprints the rules instead, and two published rates are comparable only when both agree.

It deliberately excludes the expectations a case is judged against, because the agent never sees them. That split decides what a correction costs: changing what the agent was shown invalidates the recordings and forces fresh ones, while changing only what the outcome is judged against leaves them replayable.

The identity fingerprints what was asked, not whether it can be answered. A rule change elsewhere can make a fixture's declared claim impossible to satisfy without altering anything the fingerprint covers, so the identity stays equal while the task has quietly become unanswerable. Nothing in the fingerprint detects that, and re-measuring the fixture against the current compiler is what does.

### Turn
One ask and everything the agent does to answer it: the model round-trips, the tool calls, the drafts, and the Veto's verdict on each. A Turn is the unit a rate is measured over and the unit a Cassette records.

State belongs to the Turn rather than to the session. The loop also writes to the Turn itself - a nudge after a refused draft, a compiler-authored repair - and those messages are part of the Turn they interrupt. Anything reconstructing a Turn from the wire must tell them from the next ask, which the transport does not help with: a control message the loop sends itself and a message from the user arrive in the same shape.

### Response Cassette
A provider response captured as raw JSON or SSE and replayed through the production parser. It proves transport parsing and response assembly. By itself it does not prove that the model saw the expected prompt, transcript, tools, or workspace state.

### Flow Cassette
A versioned record of one complete simulator case. It binds the initial workspace, one or more Turns, semantic model-request checkpoints, raw Response Cassettes, approval previews and decisions, canonical events, receipts, typed outcomes, exact between-Turn workspace checkpoints, and the final workspace under one content hash.

Replay validates each checkpoint before releasing its next response and runs the normal loop with approval and Veto behavior enabled. An `empirical_model` Flow Cassette may support a historical model measurement. A `deterministic_harness` Flow Cassette proves only the machinery and is excluded from convergence, first-draft, and intent denominators.

### Stand-in
A scripted responder that replaces only a live model's choice on the wire while preserving the production boundaries and state transitions around it, so the surrounding agent machinery can be exercised with no model access at all. It answers a declared range of asks and refuses everything outside it, and the refusal is the point: a range it silently outgrew would answer asks it cannot really handle.

A Stand-in can show that the machinery runs correctly and can never measure an agent. Its drafts and defect seeds are written to produce declared outcomes through the same Veto, so a First-draft veto-pass rate taken over one describes the script rather than a model.

### Defect seed
A deliberately wrong draft, kept as a fixture, whose purpose is to make a rejection path reachable without spending a model turn. Each seed declares the verdict it should receive, which makes the seed set double as a census of the rules that are actually reachable: a rule no seed trips and no recorded draft trips is advertised but unreachable, and belongs on an explicit exception list carrying the reason rather than being assumed covered. A seed whose declared verdict is a salvage, where a diagnostic is raised and then cleared before the draft is judged, is the case most easily mistaken for a pass, because the rejection path it is meant to exercise never runs.

## Guarding the repo

### Gate
A build step that fails when a repo invariant is violated, as distinct from a test that checks a behavior. A Gate is usually bidirectional: it fails both when something is missing from an allowlist and when an allowlist row no longer matches anything, so the list cannot rot in either direction.

A Gate must assert a floor on its own input before any count it reports means anything. A Gate whose corpus is empty, whose filter matches nothing, or whose build product has no consumer reports success while checking nothing, and is then cited afterwards as evidence. Deleting a Gate's input and confirming it turns red is the check that separates the two.

A floor guards the input a Gate holds, not whether that input is the one in the tree. A Gate that compiles its input list into its own executable was observed to keep running an earlier list after the list was edited, because the build reused an executable built from the old list. Such a Gate reads its data at run time instead. A Gate that reports an item no file contains any more is the sign that it holds a stale input.

A Gate that reads its subject as text at a path, or pins one line of it verbatim, depends on where that text lives as well as on what it says. Moving, splitting, or rewording the subject turns such a Gate red with nothing wrong in behavior, and a proof that the refactored product is unchanged does not reach it, because the Gate never reads the product. Such Gates are found before the change by searching every source for the subject's name and for the exact text of each line being edited, not by recalling which Gates exist.

When a Gate classifies a closed set, it must also reject inputs outside that set. Mapping an unknown member into a fallback bucket lets the declared buckets stay green while the topology the Gate reports has already changed.

The floor is necessary and not sufficient. A Gate holding a full input can still assert something weaker than its own name claims, so that runs in which the named behavior never happened satisfy it too. An assertion must name the value expected rather than the values excluded, since a difference from two wrong answers is satisfied by a third. A Gate is also only as good as the fixture beneath it: when two outcomes it is meant to separate write identical observable state, no assertion over that state can tell them apart.

The Probe that tests a Gate is itself code, and one that does not compile runs no check. Since a build that failed to compile and a Gate that passed both produce no failure message, a Probe's verdict is read from the build's exit status rather than from its output.

A Gate can satisfy every rule above and still be porous. Passing probes show that the cases they name are caught; they say nothing about the cases nobody named, and counting them by input or by file rather than by verdict hides which verdicts have no probe at all. Reading such a Gate does not expose the gap, because the holes are in what it never looks at. Applying a one-line change to a copy of its inputs and running the built Gate against them does. A prohibition stated over an open vocabulary has no terminating condition, since another spelling always exists. Requiring what the code must do is the cheaper half of the pair, because it spares the author enumerating a vocabulary that cannot be closed, but it is still a rule about the shape of the text and dead code satisfies it, so it belongs beside the prohibition rather than in place of it. A Gate whose subject stays open must declare which threat it bounds, rather than leaving a reader to assume it bounds every one.

Every failure above is a Gate that permits what it should refuse. A Gate can also refuse what it should permit, and that one hides differently. A refusal whose condition is an absence - no prior run, no baseline, no matching row - is a rule about the first occurrence of its subject, and the first occurrence is usually legitimate. Its author cannot see this from the inputs in hand, because every one of them has a prior, and a Probe does not expose it either: a Probe feeds the branch a fabricated value and confirms it refuses, which establishes that the branch runs and rejects what it names, never that reaching it is a defect. Sorting each refusal in writing into a defect the workflow cannot produce or a first the workflow produces by construction is what separates them, and producing the first legitimate input through the workflow's own step, then running that workflow to its last step, is what tests the sort. Relaxing such a refusal needs the same sort applied to the admitting branch, since what it now claims must hold in every state that reaches it.

### Probe
A deliberate edit that must make a Gate fail. It is how a Gate is shown to be load-bearing rather than merely green, because without one a Gate that checks nothing and a Gate that checks correctly look the same from outside. A Probe names the check it expects to reject it, and one caught by a different check is a Probe failure rather than agreement, since a rejection for the wrong reason says nothing about the check the Probe was written for.

The word covers two things worth keeping apart. One is a Probe a Gate carries and can run against itself, which holds the named cases caught as the Gate changes. The other is a one-off edit a reviewer applies to a copy of the Gate's inputs. Only the second can find a case nobody named, so a Gate whose whole assurance is the first kind is assured against its author's imagination and nothing wider.

A Probe must turn on a check that exists only when the property it tests holds. A Probe whose expected outcome happens whether or not the property holds, such as one that aborts unconditionally where it meant to show a safety check firing, gets that outcome either way and shows nothing.

### Frozen signature corpus
The generated type surface of every virtual-module export, used as a Gate's input so that adding an export adds a case by construction and the corpus cannot drift from what it describes.

The corpus is generated rather than written, which is what makes its coverage a fact rather than a promise: a Gate over a hand-listed corpus can pass while an export nobody listed goes unchecked. Its assertions are that every member resolves, that none reaches the unknown type by fallback rather than by declaration, and that the whole surface hashes to a pinned value, so a change to any signature is visible in a diff instead of being absorbed silently.

## Flagged ambiguities

- A value meaning "nothing here" has twice been reused for "we could not look". They are distinct: the first is a positive claim, the second admits the check did not run. Both instances shipped a passing verdict. An empty Data label set once stood for unknown provenance, so a leaking Handler proved clean; an empty edit baseline once stood for an unreadable file, so a Veto proved a destructive edit clean. The remedy in both cases was an optional type rather than a degenerate value.
