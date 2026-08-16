//! `zts-compiler` - everything that decides whether a program is proven.
//!
//! The checkers, the type system, contract extraction, path enumeration and
//! counterexample search, the semantics registry and its SMT layer, the rule,
//! idiom and restriction catalogs, and the repair machinery.
//!
//! This is the top of the tier graph. It names `zts-engine`, `zts-contracts`
//! and `zts-base`; nothing below it may name anything here. That is the whole
//! point of the boundary: the interpreter must not import the flow checker,
//! and until this module existed nothing but an allowlist stopped it.
//!
//! Embedders should import `zts`, the umbrella in `root.zig`, which re-exports
//! this module's surface alongside the other three.
//!
//! Tier membership is recorded in `scripts/zts-tiers.allow`. See
//! docs/plans/2026-08-07-021-zts-three-module-split-plan.md.

const std = @import("std");

pub const bool_checker = @import("bool_checker.zig");
pub const strict_checker = @import("strict_checker.zig");
pub const type_checker = @import("type_checker.zig");
pub const flow_checker = @import("flow_checker.zig");
pub const handler_verifier = @import("handler_verifier.zig");

pub const type_pool = @import("type_pool.zig");
pub const type_key = @import("type_key.zig");
pub const type_env = @import("type_env.zig");
pub const effect_inference = @import("effect_inference.zig");
pub const function_specs = @import("function_specs.zig");

pub const contract_builder = @import("contract_builder.zig");
pub const contract_diff = @import("contract_diff.zig");
pub const module_facts = @import("module_facts.zig");
pub const module_types = @import("module_types.zig");
pub const manifest_registry = @import("manifest_registry.zig");
pub const module_spec_render = @import("module_spec_render.zig");

pub const path_generator = @import("path_generator.zig");
pub const counterexample = @import("counterexample.zig");
pub const fault_coverage = @import("fault_coverage.zig");
pub const behavior_canonical = @import("behavior_canonical.zig");
pub const proof_trace = @import("proof_trace.zig");
pub const witness_corpus = @import("witness_corpus.zig");
pub const spec_discharge = @import("spec_discharge.zig");
pub const property_diagnostics = @import("property_diagnostics.zig");
pub const diagnostic_catalog = @import("diagnostic_catalog.zig");
pub const diagnostic_projection = @import("diagnostic_projection.zig");

pub const ambient_names = @import("ambient_names.zig");
pub const grammar_registry = @import("grammar_registry.zig");
pub const tsx_frontend_registry = @import("tsx_frontend_registry.zig");
pub const source_identity = @import("source_identity.zig");
pub const rule_registry = @import("rule_registry.zig");
pub const idiom_registry = @import("idiom_registry.zig");
pub const restriction_registry = @import("restriction_registry.zig");

pub const repair_intent = @import("repair_intent.zig");
pub const repair_plan = @import("repair_plan.zig");
pub const ir_identity = @import("ir_identity.zig");
pub const kernel_identity = @import("kernel_identity.zig");
pub const repair_validator = @import("repair_validator.zig");

pub const semantics = @import("semantics.zig");
pub const semantics_check = @import("semantics_check.zig");
pub const semantics_smt = @import("semantics_smt.zig");
pub const semantics_audit = @import("semantics_audit.zig");
pub const semantics_corpus = @import("semantics_corpus.zig");
pub const semantics_render = @import("semantics_render.zig");

pub const pipeline = @import("pipeline.zig");
pub const system_linker = @import("system_linker.zig");
pub const sql_analysis = @import("sql_analysis.zig");
pub const api_schema = @import("api_schema.zig");

test {
    std.testing.refAllDecls(@This());
}
