# Concepts

Shared domain vocabulary for this project — entities, named processes, and status concepts with project-specific meaning. Seeded with core domain vocabulary, then accretes as ce-compound and ce-compound-refresh process learnings; direct edits are fine. Glossary only, not a spec or catch-all.

## Proving a handler

### Handler
The single function a deployed program exposes, taking a request and returning a response. It is the unit the compiler proves: properties, capabilities, and declared obligations are all stated about a Handler, and helpers it calls are judged by what they contribute to it.

### Property
A fact the compiler either proves about a Handler or declines to prove — that it leaks no secret, that it answers the same way on every run, that it is safe to retry. A Property is never partially held: it is proven, or it is not, and an unproven Property is reported rather than assumed false-and-forgotten.

Some Properties are derived from others rather than observed directly, so a change to what decides one silently changes the derived one. Anything deriving a Property must be recomputed after the deciding answer lands, not before.

### Proof profile
The set of Properties a Handler must discharge. A Handler that declares nothing is held to the full default profile; one that declares a Spec is held to exactly what it declared. Declaring a narrow Spec is how an author trades a proven guarantee for the freedom to do something the full profile forbids.

### Spec
An author's declaration, written on the Handler's return type, of which Properties it claims. The compiler discharges each claim against what it inferred; a claim it cannot discharge is an error, not a warning.

### Proof capsule
The same declaration applied to a helper rather than the Handler. A capsule is what lets a proof compose across a call boundary: without one, a helper that breaks a Property the Handler needs makes the Handler's proof fail, because nothing states what the helper promises.

### Effects ceiling
A declared upper bound on the Capabilities a function may reach. The inferred set must sit inside the ceiling; reaching past it is an error, and declaring a Capability never reached is a warning, so the ceiling stays honest in both directions.

## Tracking data through a handler

### Data label
A mark on a value recording where it came from — an environment secret, a caller's credential, request input, a clock or randomness read, or an explicit record that the analysis could not tell. Labels propagate through the operations a value passes through, so a value assembled from a labelled one carries the label.

The empty set of labels is a positive claim that a value carries nothing, not an absence of information. Code that cannot determine a value's provenance must say so with the label that means "could not follow", because returning the empty set instead asserts cleanliness the analysis never established.

### Sink
A position where a value leaves the program — a response body, a log, or an outbound request. Sinks are where Data labels are judged: a label arriving at a Sink is what costs a Property, and each Sink decides a different set of Properties, since a value reaching a log is not the same disclosure as one reaching a client.

### Capability
A kind of authority a function reaches for: reading the clock, drawing randomness, reading configuration, writing to storage, talking to the network. Capabilities are declared per module export and enforced where the call happens, so authority is visible in the contract rather than discovered at runtime.

### Replay boundary
A point where a value is recorded on the first run and reproduced on later ones. Values crossing it stop varying between runs, so the marks that mean "differs per run" are cleared there — but marks about disclosure are not, because a secret that was recorded is still a secret when it is replayed.

## Measuring the compiler

### Veto
The compiler's refusal of a Handler that does not discharge its Proof profile. The Veto is the mechanism the project's central claim rests on: that the set of programs an agent writes converges on the set the compiler can prove.

At edit time the Veto answers a narrower question than its name suggests. It counts the violations a draft introduces *relative to a baseline* - the prior content of the file - and passes when that count is zero. It is not a compare-and-swap against what is on disk, and it has no opinion on what the draft removes: deleting correct code introduces no violation. A caller that supplies an empty or absent baseline therefore gets a clean verdict from a working Veto, which is how a destructive edit once proved clean.

### First-draft veto-pass rate
The share of prompts whose first generated attempt clears the Veto with no retries, counted over a frozen corpus. Retries are excluded deliberately — a rate counting them would measure a retry loop's persistence rather than the agent's aim.

### Policy hash
A fingerprint of the compiler's rule set, recorded beside every published rate so two measurements taken under different rules are never compared as though they were the same. It covers the rules and not the analysis behind them, so a change to what a rule concludes can leave it identical; the build a measurement came from is what distinguishes those.

## Guarding the repo

### Gate
A build step that fails when a repo invariant is violated, as distinct from a test that checks a behavior. A Gate is usually bidirectional: it fails both when something is missing from an allowlist and when an allowlist row no longer matches anything, so the list cannot rot in either direction.

A Gate must assert a floor on its own input before any count it reports means anything. A Gate whose corpus is empty, whose filter matches nothing, or whose build product has no consumer reports success while checking nothing, and is then cited afterwards as evidence. Deleting a Gate's input and confirming it turns red is the check that separates the two.

## Flagged ambiguities

- A value meaning "nothing here" has twice been reused for "we could not look". They are distinct: the first is a positive claim, the second admits the check did not run. Both instances shipped a passing verdict. An empty Data label set once stood for unknown provenance, so a leaking Handler proved clean; an empty edit baseline once stood for an unreadable file, so a Veto proved a destructive edit clean. The remedy in both cases was an optional type rather than a degenerate value.
