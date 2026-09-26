//! Repository shell gates: module boundaries, swallowed errors, layering,
//! release evidence, and docs drift against the registry.

const std = @import("std");
const Context = @import("Context.zig");
const tooling = @import("tooling.zig");

pub fn addCapabilityAudit(ctx: Context) *std.Build.Step.Run {
    return ctx.addGate(&.{ "/bin/bash", "scripts/check-capability-helpers.sh" }, "test-capability-audit", "Run capability helper audit").run;
}

pub const Result = struct {
    module_boundary: *std.Build.Step.Run,
    release_workflow: *std.Build.Step.Run,
    proof_swallow: *std.Build.Step.Run,
    zts_layering: *std.Build.Step.Run,
    convergence_emitter: *std.Build.Step.Run,
    evidence_marker: *std.Build.Step.Run,
    expert_qualification_boundary: *std.Build.Step.Run,
    docs_drift_step: *std.Build.Step,
    meta_drift: *std.Build.Step.Run,
    doc_links: *std.Build.Step.Run,
};

pub fn add(ctx: Context, tools: tooling.Result) Result {
    const module_boundary = ctx.addGate(&.{ "/bin/bash", "scripts/test-module-boundary.sh" }, "test-module-boundary", "Check consumer reach into zts internals against the allowlist");
    const release_workflow = ctx.addGate(&.{ "/bin/bash", "scripts/test-release-workflow.sh" }, "test-release-workflow", "Check release workflow invariants");
    const proof_swallow = ctx.addGate(&.{ "/bin/bash", "scripts/check-proof-swallow.sh" }, "test-proof-swallow", "Check the proof pipeline for unreviewed swallowed errors");
    const zts_layering = ctx.addGate(&.{ "/bin/bash", "scripts/check-zts-layering.sh" }, "test-zts-layering", "Check zts tier assignments import only downward");
    const convergence_emitter = ctx.addGate(&.{ "/bin/bash", "scripts/check-convergence-emitter.sh" }, "test-convergence-emitter", "Check the convergence marker has one producer and one consumer");

    const evidence_marker = ctx.addGate(&.{ "/bin/bash", "scripts/test-evidence-marker.sh" }, "test-evidence-marker", "Check release evidence marker and publisher boundaries");
    evidence_marker.run.step.dependOn(&tools.run_release_provenance_tests.step);

    const expert_qualification_boundary = ctx.addGate(&.{
        "python3",
        "scripts/test-expert-qualification.py",
    }, "test-expert-qualification", "Check report-only expert qualification boundaries");

    const docs_drift = ctx.addGate(&.{ "/bin/bash", "scripts/check-docs-drift.sh" }, "test-docs-drift", "Check docs against current registry and build paths");
    _ = ctx.addGate(&.{ "/bin/bash", "scripts/check-idiom-table.sh" }, "test-idiom-table", "Check spec 4.2.1's idiom table against the registry");
    _ = ctx.addGate(&.{ "/bin/bash", "scripts/check-canonical-style.sh" }, "test-canonical-style", "Check the canonical-style skill's examples against the rule registry");
    _ = ctx.addGate(&.{ "/bin/bash", "scripts/check-grammar-drift.sh" }, "test-grammar-drift", "Check spec section 8's grammar against the registry");
    _ = ctx.addGate(&.{ "/bin/bash", "scripts/check-decision-registry.sh" }, "test-decision-registry", "Check every published decision kind is emitted somewhere");
    // artifacts.zig appends the built `zts` binary to this gate's arguments.
    const meta_drift = ctx.addGate(&.{ "/bin/bash", "scripts/check-meta-drift.sh" }, "test-meta-drift", "Check meta's published registry hashes against their pins");
    const doc_links = ctx.addGate(&.{ "/bin/bash", "scripts/audit-docs.sh" }, "test-doc-links", "Check docs for broken relative links");

    return .{
        .module_boundary = module_boundary.run,
        .release_workflow = release_workflow.run,
        .proof_swallow = proof_swallow.run,
        .zts_layering = zts_layering.run,
        .convergence_emitter = convergence_emitter.run,
        .evidence_marker = evidence_marker.run,
        .expert_qualification_boundary = expert_qualification_boundary.run,
        .docs_drift_step = docs_drift.step,
        .meta_drift = meta_drift.run,
        .doc_links = doc_links.run,
    };
}
