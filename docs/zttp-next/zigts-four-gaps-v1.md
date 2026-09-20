# zigts: the four properties outside the guarantee
## Companion to draft v0.6, version 1 (2026-09-15)

> **Added when this file was tracked, 2026-09-20.** Draft v0.6 is not in this
> repository; [zigts-tools-extension-v0_7.md](zigts-tools-extension-v0_7.md)
> supersedes it and is. Read this document as the input it was, not as a
> statement of what is still open. v0.7 took up gap 1 as the `subject` route
> parameter in 5.2 and the `entitled` relationship check in 35.1, which it
> credits to "the four-gaps document"; gap 2 as effect classes and the approval
> marks that consequential routes require in 36.2; and it states in 39 what Part
> D still does not close, which is where gaps 3 and 4 largely remain. The
> section numbers cited below are v0.6's and still resolve in v0.7, which keeps
> 1 to 32 and adds 33 to 39.

Draft v0.6 guarantees four things about an agent-submitted plan: it cannot perform an action outside the certified tools' authority, create a flow the lattice forbids, exceed a budget, or serve a purpose the observation lacks. That is what "the agent cannot execute illegal actions" means in the spec, and it should be written into section 1 in those words.

Four properties fall outside it. This document states each, says why the current contracts cannot see it, names the incident it produces, lists candidate mechanisms with their prior art, and ends with what still needs research. The intent is that each gap becomes either a section in v0.7 or a stated non-goal, and nothing stays implicit.

A note on the authorization-vendor framing (Brossard, Axiomatics, June 2026). The claim that AI exposes an existing authorization gap rather than creating a new one is right, and its list of decision attributes maps almost exactly onto these four gaps. Its architecture, a central policy decision point evaluated at runtime for every request, is not the right primary mechanism here: the spec decides statically at verification and checks scope per invocation, which is cheaper, deterministic and replayable. What the framing does contribute is vocabulary auditors already know (policy administration, decision, enforcement and information points), an attribute set to check the observation model against, and one structural point taken up under gaps 1 and 2: the two decisions that cannot be made statically, which subject and whether a consequential effect may proceed, need a small, deterministic, journaled runtime decision, and that is the one place a decision point belongs.

---

## Gap 1. Instance-level authority: which subject

**Statement.** A tool with authority for `GET /reports/{id}` fetches whichever report the model names. The route list bounds the kind of action; nothing bounds the instance. A listed brand endorses any well-formed id, and the flow from that report to `Output` is permitted by policy.

**Why the contracts miss it.** Authority, routes, flow, cost and purpose are all properties of code and of the observation. The subject is a runtime value. The verifier never sees which customer a plan is about, and the capability layer sees only that the parameter is well-formed.

**The incident.** A plan under an observation opened for customer A names customer B's id. Every contract passes. B's report reaches the model. In this domain that is the most common illegal action there is, and it is also the GitHub MCP shape (read one resource, write another, one credential), which route-level origins made visible only when the flow crosses routes.

**Candidate mechanisms, strongest first.**

1. *Observation-bound parameters.* The observation carries the subjects it is about; the capability layer fills route parameters marked `subject` from the observation and refuses values from the tool. The model cannot name a subject at all. Cheapest, deterministic, no new component. Fails for plans that legitimately touch subjects discovered at runtime (a search that returns ids).
2. *Static pre-clearance at verification.* Subjects that arrive in the plan's declared `input` are known at submission. The verifier checks them against the observation's entitlement before execution, so the common case stays static. Only subjects derived from tool outputs at runtime fall through to 3.
3. *A runtime relationship check at the capability layer.* Before a `subject`-marked parameter is used, the capability layer asks "may this observation touch this subject on this route" against a relationship store. This is the Zanzibar model (Pang et al., USENIX ATC 2019), implemented in the open by OpenFGA and SpiceDB, and the same shape as row-level security in a database. The answer is journaled with the observation's snapshot token so replay reproduces it.
4. *Upstream-scoped credentials.* Per-observation attenuation of the host credential to (route, subject) by caveats (Macaroons, Biscuit) or exchange (RFC 8693), so the upstream refuses what the capability layer would have. Strongest in principle, depends entirely on upstream support, which the research pass found narrow.

**Spec hooks.** Route parameters gain a `subject` marker in 5.2; the observation gains a subject set and an entitlement source in 20; a `subject-check` row in 22's journal. The existing item in 32 becomes this section.

**Research.** Which upstreams in the deployment accept scoped credentials at all. Zanzibar-style check latency and consistency semantics at the capability layer's call rate. Whether pre-clearance at verification covers a large enough share of plans that the runtime check stays rare. How FCRA consent and permissible-purpose records map onto relationship tuples, so the entitlement source is the compliance record rather than a copy of it.

---

## Gap 2. Legal tools, wrong decisions: consequential effects

**Statement.** The model can send the wrong notice, close the wrong case or approve the wrong applicant through tools entirely within authority. Flow and cost say nothing. The action is legal and wrong.

**Why the contracts miss it.** Correctness of a decision is not a property of code or of the observation. It is a property of the world the tool acts on, which no static contract can see.

**The incident.** An injected instruction in a retrieved document steers a plan toward an allowed `POST /cases/{id}/close`. Plan-then-execute prevents the injection from adding a tool; it does not prevent it from choosing arguments to a tool the plan already had. That limitation is documented for the pattern and it applies here.

**Candidate mechanisms.**

1. *Effect classes on routes.* 5.2 already splits `get` from effects. Extend to four classes declared per route: read; reversible effect (has an undo or a compensating route); irreversible effect; consequential effect (irreversible and material: money, legal notice, records disclosure). Classes live in the manifest, so they are static and audited.
2. *Plan-level approval, not action-level.* A plan's routes are known at verification, and after gap 1 so are its subjects. A consequential plan can therefore be shown to a human as "these effects on these subjects" before anything runs, and approved once. This is Terraform's plan-then-apply applied to agents, and it avoids the confirmation-per-action fatigue that CaMeL's user-confirmation fallback and the OWASP excessive-agency guidance both accept as a cost. The approval is an observation attribute that unlocks exactly the (route, subject) pairs approved, for one invocation.
3. *Dual control for the top class.* Two approvals from distinct principals for consequential effects, the finance two-person rule, expressed as a policy row rather than code.
4. *Rate limits and budgets per effect class.* A cap on consequential effects per observation and per time window, so a compromised session's blast radius is bounded even when approvals are obtained.
5. *Idempotency and compensation.* Every effect route carries an idempotency key derived from (plan-hash, node id, inputs), so retries after failure do not repeat effects; reversible routes name their compensating route so a failed plan can be unwound where the upstream allows.
6. *Preview mode.* Effect routes may declare a dry-run form; the plan runs to the point of effect, the intended requests are journaled, and nothing is sent until approval.

**Spec hooks.** Effect class in the route grammar (5.2) and the manifest (6); approval and dual-control as policy rows (9.4) keyed by effect class; approval as an observation attribute checked per invocation (20); idempotency keys and compensating routes in the journal (22); a consequential-effect budget alongside `calls` (8).

**Research.** Evidence on confirmation fatigue and on plan-level versus action-level approval in agent products. Approval flows in workflow engines (Step Functions callback tasks, Temporal signals) as the mechanics for a pending approval that survives the observation's lifetime. Idempotency-key designs at payment providers as the template for effect routes. Whether any published agent framework classifies effects as more than a read/write bit (MCP tool annotations carry a destructive hint; what else exists).

---

## Gap 3. The model's own context: guarantees end at the boundary

**Statement.** `Output` is a sink, and everything the lattice allows to reach it the model may repeat anywhere. zttp closes the exfiltration leg of the lethal trifecta for its own tools. If the agent also holds tools outside zttp, the boundary is the union of all its tools. Aggregation across observations lives here too: the disclosure ledger sees what left through `Output`; the model's memory sees the same and is governed by nothing.

**Why the contracts miss it.** The lattice ends at `Output` by construction. Labels do not leave the guest, and the model's context has no labels.

**The incident.** A plan legitimately returns a customer's summary to the model. The agent's email tool, outside zttp, sends it to an address supplied by an injected instruction. Every zttp contract held. Documented instances of this shape exist for assistants with a read tool and any exfiltration channel.

**Candidate mechanisms.**

1. *zttp is the only tool surface.* The agent runs with zttp tools and nothing else, so the boundary and the agent's tool set coincide. This is the strongest option and the one the certified-agent packaging already assumes. It is a deployment stance, not a mechanism, and it should be stated as a requirement for the guarantees to hold.
2. *Labels leave the guest with the data.* `Output` values carry their label set out to the agent runtime, which refuses to pass labelled data to tools that are not zttp tools, or downgrades by type. This is the FIDES arrangement (Microsoft, 2025), which propagates labels through the planner and declassifies only low-capacity types. It requires an agent runtime that honours labels; none of the mainstream frameworks does without modification.
3. *Context minimisation.* Plans return the smallest type that serves the observation, which is what typed `Output` already encourages; a policy row can forbid wide records reaching `Output` when a narrower brand exists.
4. *Session-scoped memory.* The agent's memory across observations is cleared or labelled per observation, so cross-observation aggregation in the model's context is bounded by what the ledger already bounds.
5. *Egress inspection outside zttp.* Data-loss-prevention on the agent's other tools as a last resort. Weak, since it works on patterns rather than labels, and stated as such.

**Spec hooks.** A requirement in section 1 or 24 that the guarantees hold for an agent whose tools are all zttp tools, and a statement of what degrades otherwise. A `labels` field on `Output` at the host channel (28.4) so an agent runtime that can honour them has something to honour.

**Research.** Which agent runtimes carry provenance or labels on tool results (FIDES's evaluation, CaMeL's capabilities, anything in production frameworks). Whether MCP's tool result shape can carry labels without breaking clients. Documented exfiltration incidents through non-zttp channels in assistants that had otherwise sound tool controls, to calibrate how much of the risk option 1 removes.

---

## Gap 4. The tool supply chain: the handler is the trusted computing base

**Statement.** Full safety at the handler level makes the handler the TCB. A certified tool's authority, brands, cost table and flow summary are trusted by every plan that calls it. The risk moves from the agent to whoever writes, reviews and compiles tools.

**Why the contracts miss it.** Contracts describe a tool; they do not judge it. A tool whose summary is correct and whose behaviour is malicious within that summary passes every check. The eBPF helper-contract failures are the same class: the verifier trusts what the helper declares.

**The incident.** A third-party tool with a legitimate route list carries an over-broad brand constructor, or a doc comment that instructs the model (tool-description injection was demonstrated against MCP servers in 2025), or a later version that changes behaviour under an unchanged description. Every plan built on it inherits the defect.

**Candidate mechanisms.**

1. *Audit records per tool version.* Borrow cargo-vet's model: every tool version carries a signed audit record naming the reviewer, the criteria met, and the delta from the last audited version. Policy requires audits at a named level before a tool enters the manifest. The compiler-derived artifacts make the audit cheap, since a reviewer reads ten lines of imports, a route list and a flow summary rather than the code.
2. *Review criteria bound to the derived artifacts.* A checklist per artifact: authority set justified by purpose; routes minimal; brands sink-specific and tested against malformed input; descriptions free of instructions to the model; cost table rows present for every primitive used; declassification absent or justified.
3. *Differential testing of summaries.* The reference-model item from v0.6's section 32: a dynamic-taint interpreter runs each tool on generated inputs and its observed flows are compared with the compiler's static summary; a mismatch fails certification. This is the check that turns "the summary is trusted" into "the summary was tested".
4. *Provenance for the manifest.* Tool source digest, compiler version, cost-table hash and audit records travel with the manifest entry (in-toto attestations, SLSA-style provenance), so a manifest cannot contain a tool nobody can trace.
5. *Update discipline.* A new tool version is a new manifest hash and invalidates certificates (already so); add that it also requires a new audit record at the same level, so a "rug pull" update cannot ride on an old audit.
6. *Description hygiene.* Model-facing descriptions are compiler-derived from doc comments; the compiler rejects doc comments containing imperative instructions or anything outside a declared description grammar.

**Spec hooks.** Audit records as a manifest field (6, 21); review criteria as an appendix; description grammar as a restriction (11); differential testing as a certification step (12).

**Research.** cargo-vet and cargo-crev outcomes: how much audit coverage they achieved and what slipped through. Review-based marketplaces as a cautionary comparable: rates at which reviewed browser extensions still shipped malicious updates. MCP tool-poisoning and rug-pull demonstrations and the mitigations vendors adopted. Whether any published system differentially tests static flow summaries against a dynamic oracle, since the v0.6 research pass found none.

---

## What the article contributes, item by item

| article attribute or question | where it lands |
|---|---|
| resource being accessed; "this specific document" | gap 1 |
| "only after human approval"; risk indicators | gap 2; risk as an observation attribute that narrows scope between invocations (20 already re-checks) |
| "summarize but not export" | already stronger in the spec: flow labels and sinks decide this statically, which attribute-based evaluation cannot express |
| data classification; regulatory requirements; business purpose | 9.4 namespace classes and 9.8 purpose |
| geographic location; data residency | not in the spec; a residency attribute on routes and namespaces plus one policy row is cheap and should be added |
| "why access was granted, under which policy" | certificate plus journal; add a per-sink decision trace naming the policy row that allowed it, the equivalent of a decision log |
| aggregation "never intended to be combined" | 9.8 aggregation predicates and the disclosure ledger |
| central policy evaluated consistently | the deployment policy is already one artifact by hash; adopt the four-point vocabulary for auditors, not the runtime-per-request model |
