# Product proposals

These documents support product decisions. They do not describe the complete
implemented surface and do not authorize work. The project owner selects a
release boundary through [Roadmap](../roadmap.md#proposal-decisions). An
accepted scope then gets a dated implementation plan under `docs/plans/`.

| Document | Status | Decision needed |
|---|---|---|
| [Agent tool extension v0.7](zigts-tools-extension-v0_7.md) | Parked draft | Select a customer need, tool profile, and deployment threat model before implementation |
| [Four gaps](zigts-four-gaps-v1.md) | Historical analysis of draft v0.6 | Recheck its authority and disclosure concerns against any selected scope |
| [Proposed v1.0 scope and v1.x roadmap](zttp-v1.0-scope-and-v1x-roadmap.md) | Parked recommendation | Accept or revise the release boundary; its milestone labels are local to that proposal |

The [custom agent-handler specification](../plans/2026-09-19-feat-agent-handler-spec.md)
is also proposed. Its catalog, capability, streaming, and artifact work must be
reconciled with the tool extension before either is selected.

The [exported boundary-type draft](../archive/plans/zts-advanced-v2.1.md) moved
to the archive because its language increment shipped. Current language
behavior is documented in [TypeScript](../typescript.md) and the
[formal specification](../zts-formal-spec-northstar-advanced.md).
